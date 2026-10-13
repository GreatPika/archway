"""Contract-test validator only; not package/helper implementation."""
import json, pathlib, unicodedata, re
from urllib.parse import quote, urlsplit, unquote
from jsonschema import Draft202012Validator
D=pathlib.Path(__file__).parent
REQUEST=json.loads((D/'request.schema.json').read_text()); RESPONSE=json.loads((D/'response.schema.json').read_text())
for schema in [REQUEST,RESPONSE]: Draft202012Validator.check_schema(schema)
def validate(request,response,exit_code=0):
    Draft202012Validator(REQUEST).validate(request); Draft202012Validator(RESPONSE).validate(response)
    def check(ok,msg):
        if not ok:raise ValueError(msg)
    check(exit_code==0,'Nonzero exit invalidates envelope')
    def path_ok(path):
        return path==unicodedata.normalize('NFC',path) and not path.startswith('/') and not re.match(r'^[A-Za-z]:',path) and '\\' not in path and '\x00' not in path and all(p not in ('','.','..') for p in path.split('/'))
    def uri_ok(uri):
        parts=urlsplit(uri)
        return parts.scheme=='file' and not parts.netloc and parts.path.startswith('/') and not parts.query and not parts.fragment and not re.search(r'%(?![0-9a-fA-F]{2})',uri) and '\x00' not in unquote(uri)
    def hop_uri_ok(uri):
        if not uri_ok(uri) or re.search(r'\s', uri):return False
        path = unquote(urlsplit(uri).path, errors='strict')
        path.encode('utf-8', errors='strict')
        return (not path.endswith('/') and
                all(part not in ('', '.', '..') for part in path.split('/')[1:]) and
                quote(path, safe='/:') == urlsplit(uri).path)
    check(uri_ok(request['root_uri']),'Invalid root URI')
    for path in [request['config_path']]+request['expected_files']:check(path_ok(path),'Invalid repository path')

    for key in ['protocol_version','request_id','project_id']:check(request[key]==response[key],'Request correlation '+key)
    check(request['expected_files']==sorted(request['expected_files']),'Expected corpus must be sorted')
    files=response['files']; paths=[f['path'] for f in files]
    check(paths==request['expected_files'],'Exact sorted coverage required')
    inputs={i['id']:i for i in response['inputs']}
    check(len(inputs)==len(response['inputs']),'Duplicate input id')
    observations={}
    for i in inputs.values():
        for hop in i['symlink_hops']:
            check(hop_uri_ok(hop['observed_uri']), 'Invalid symlink URI')
            # Preserve raw text: no NFC or path normalization before comparison.
            hop['target'].encode('utf-8', errors='strict')
        # Hop disagreements are freshness evidence, not malformed structure.
        signature=(i['kind'],i['canonical_uri'],i.get('sha256'))
        check(i['observed_uri'] not in observations or observations[i['observed_uri']]==signature,'Conflicting observed input identity')
        observations[i['observed_uri']]=signature
        check(uri_ok(i['observed_uri']) and (i['canonical_uri'] is None or uri_ok(i['canonical_uri'])),'Invalid input URI')
        check((i['canonical_uri'] is None)==(i['kind']=='absent'),'Physical identity required for existing inputs')
    check(any(i['kind']=='file' and i['observed_uri']==(request['root_uri'] if request['root_uri'].endswith('/') else request['root_uri']+'/')+quote(request['config_path'],safe='/') for i in inputs.values()) or response['status']=='failed','Missing config provenance')
    for f in files:
        check(f['membership']!='unknown' or f['coverage']=='failed','Unknown membership coverage')
        check((f['membership']=='nonmember')==(f['coverage']=='not_applicable'),'Nonmember coverage mismatch')
        check(f['membership']=='member' or f['input_id'] is None,'Nonmember/unknown source input')
        if f['membership']=='member' and f['coverage']!='failed':check(f['input_id'] in inputs and inputs[f['input_id']]['kind']=='file','Missing source provenance')
        if f['input_id'] is not None:
            check(f['input_id'] in inputs and inputs[f['input_id']]['observed_uri']==(request['root_uri'] if request['root_uri'].endswith('/') else request['root_uri']+'/')+quote(f['path'],safe='/'),'Source identity mismatch')
            check(inputs[f['input_id']]['canonical_uri']==inputs[f['input_id']]['observed_uri'],'Corpus source canonical alias/outside root')
    for fact in response['facts']:
        check(fact['source'] in paths,'Unexpected source')
        resolution=fact['resolution']
        if resolution['kind']=='local':
            check(uri_ok(resolution['canonical_file_uri']),'Invalid target URI')
            check(resolution['via_path'] is None or uri_ok(resolution['via_path']),'Invalid alias URI')
            check(resolution['path'] is None or path_ok(resolution['path']),'Invalid target path')
            root_prefix=(request['root_uri'] if request['root_uri'].endswith('/') else request['root_uri']+'/')
            if resolution['path'] is not None:
                check(resolution['canonical_file_uri']==root_prefix+quote(resolution['path'],safe='/'),'Target repository path/URI mismatch')
            else:
                check(not resolution['canonical_file_uri'].startswith(root_prefix),'In-root target requires repository path')
            check(any(i['kind']=='file' and i['canonical_uri']==resolution['canonical_file_uri'] and i['id'] in fact['input_ids'] for i in inputs.values()),'Missing local target provenance')

        check(fact['source_range']['path']==fact['source'],'Range source mismatch')
        check(all(i in inputs for i in fact['input_ids']),'Dangling input reference')
        sourcefile=files[paths.index(fact['source'])]
        check(sourcefile['membership']=='member' and sourcefile['coverage'] not in ('failed','not_applicable') and sourcefile['input_id'] in fact['input_ids'],'Fact from unverified source')
    for item in response['facts']+response['unknowns']+response['tool_errors']:
        r=item['source_range']
        if r is not None:
            start=(r['start']['line'],r['start']['column']);end=(r['end']['line'],r['end']['column'])
            check(start<end if 'specifier' in item else start<=end,'Empty edge or reversed range')
        if 'path' in item and r is not None:check(item['path']==r['path'],'Diagnostic span mismatch')
    if response['status']=='complete':
        check(all((f['membership']=='member' and f['coverage']=='complete') or f['membership']=='nonmember' for f in files),'Incomplete coverage')
        check(not response['unknowns'] and not response['tool_errors'],'Complete with diagnostics')
        check(all(f['resolution']['kind']!='unresolved' for f in response['facts']),'Unresolved marked complete')
    if response['status']=='incomplete':check(bool(response['unknowns'] or response['tool_errors']),'Missing incomplete explanation')
    if response['status']=='failed':check(bool(response['tool_errors']),'Missing failure explanation')
    return True

def decode_envelope(raw):
    """Strict test-level framing; json.loads itself rejects extra values/BOM."""
    def unique(pairs):
        result={}
        for key,value in pairs:
            if key in result:raise ValueError('Duplicate object key')
            result[key]=value
        return result
    def bad_constant(value):raise ValueError('Non-JSON numeric constant')
    return json.loads(raw.decode('utf-8',errors='strict'),object_pairs_hook=unique,parse_constant=bad_constant)

def validate_transport(request_bytes,stdout_bytes,stderr_bytes,elapsed_seconds,exit_code,eof):
    if request_bytes>8*1048576 or stdout_bytes>64*1048576 or stderr_bytes>256*1024:raise ValueError('Transport size exceeded')
    if elapsed_seconds>120 or exit_code!=0 or not eof:raise ValueError('Transport invalid')
