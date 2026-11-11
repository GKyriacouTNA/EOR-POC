import json, os, sys, uuid
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "vendor"))
import pg8000.native

def audit(c,e,entity,at): c.run("INSERT INTO archive.metadata_change_event (metadata_change_event_id,source_event_id,entity_type,entity_id,entity_key,change_type,outcome,processing_status,changes,raw_change_payload,changed_at,processed_at,changed_by_id,changed_by_name,change_reason,source_system) VALUES (:id,:eid,:t,:entity,CAST(:key AS jsonb),'U','updated','processed',CAST(:ch AS jsonb),CAST(:raw AS jsonb),:at,clock_timestamp(),:by,:name,:why,:source)",id=str(uuid.uuid4()),eid=e["event_id"],t=e["entity_type"],entity=entity,key=json.dumps(e["entity_key"]),ch=json.dumps(e["changes"]),raw=json.dumps(e),at=at,by=e["changed_by"]["id"],name=e["changed_by"].get("name"),why=e["reason"],source=e["source"])

def apply_event(e):
    eid=str(uuid.UUID(e["event_id"])); typ=e["entity_type"]
    c=pg8000.native.Connection(host=os.environ["DB_HOST"],port=int(os.environ["DB_PORT"]),database=os.environ["DB_NAME"],user=os.environ["DB_USERNAME"],password=os.environ["DB_PASSWORD"])
    try:
        c.run("BEGIN")
        if c.run("SELECT 1 FROM archive.metadata_change_event WHERE source_event_id=:e",e=eid): c.run("COMMIT"); return {"outcome":"duplicate"}
        # The database, not the caller, defines the effective change time. One
        # timestamp is reused for the current-row update, SCD history, and audit.
        at=c.run("SELECT clock_timestamp()")[0][0]; by=e["changed_by"]["id"]; name=e["changed_by"].get("name"); why=e["reason"]
        if typ == "version":
            i=e["entity_key"]["version_id"]; old=c.run("SELECT record_id,version_number,default_title_code,default_description_code,default_path_code FROM archive.version WHERE version_id=:i FOR UPDATE",i=i)[0]
            c.run("UPDATE archive.version SET default_title_code=COALESCE(:t,default_title_code),default_description_code=COALESCE(:d,default_description_code),default_path_code=COALESCE(:p,default_path_code),updated_at=:at WHERE version_id=:i",t=e["changes"].get("default_title_code"),d=e["changes"].get("default_description_code"),p=e["changes"].get("default_path_code"),at=at,i=i)
            c.run("UPDATE history.version SET is_current=false,valid_to=:at WHERE version_id=:i AND is_current",at=at,i=i)
            c.run("INSERT INTO history.version VALUES (:row,:i,:r,:n,:t,:d,:p,:at,NULL,true,:at,:by,:name,:why,:e)",row=str(uuid.uuid4()),i=i,r=old[0],n=old[1],t=e["changes"].get("default_title_code",old[2]),d=e["changes"].get("default_description_code",old[3]),p=e["changes"].get("default_path_code",old[4]),at=at,by=by,name=name,why=why,e=eid)
        elif typ == "version_title":
            i=e["entity_key"]["version_title_id"]; old=c.run("SELECT version_id,title_code,title_text,language_code,variant_code FROM archive.version_title WHERE version_title_id=:i FOR UPDATE",i=i)[0]
            text=e["changes"].get("title_text",old[2]); c.run("UPDATE archive.version_title SET title_text=:x,updated_at=:at WHERE version_title_id=:i",x=text,at=at,i=i)
            c.run("UPDATE history.version_title SET is_current=false,valid_to=:at WHERE version_title_id=:i AND is_current",at=at,i=i)
            c.run("INSERT INTO history.version_title VALUES (:row,:i,:v,:code,:text,:lang,:variant,:at,NULL,true,:at,:by,:name,:why,:e)",row=str(uuid.uuid4()),i=i,v=old[0],code=old[1],text=text,lang=old[3],variant=old[4],at=at,by=by,name=name,why=why,e=eid)
        elif typ == "closure":
            i=e["entity_key"]["closure_id"]; old=c.run("SELECT version_id,version_title_id,version_description_id,version_path_id,closure_code,status,review_date FROM archive.closure WHERE closure_id=:i FOR UPDATE",i=i)[0]
            status=e["changes"].get("status",old[5]); c.run("UPDATE archive.closure SET status=:s,updated_at=:at WHERE closure_id=:i",s=status,at=at,i=i)
            c.run("UPDATE history.closure SET is_current=false,valid_to=:at WHERE closure_id=:i AND is_current",at=at,i=i)
            c.run("INSERT INTO history.closure VALUES (:row,:i,:v,:t,:d,:p,:code,:status,:review,:at,NULL,true,:at,:by,:name,:why,:e)",row=str(uuid.uuid4()),i=i,v=old[0],t=old[1],d=old[2],p=old[3],code=old[4],status=status,review=old[6],at=at,by=by,name=name,why=why,e=eid)
        else: raise ValueError("unsupported entity_type")
        audit(c,e,i,at); c.run("COMMIT"); result={"outcome":"updated","entity_type":typ,"entity_id":i}; print(json.dumps(result)); return result
    finally: c.close()

def handler(event, context):
    if "Records" not in event: return apply_event(event)
    failures=[]
    for r in event["Records"]:
        try: apply_event(json.loads(r["body"]))
        except Exception as x: print(str(x)); failures.append({"itemIdentifier":r["messageId"]})
    return {"batchItemFailures":failures}
