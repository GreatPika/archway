import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/npm_native_fixture.dart';

void main() {
  late Directory root;
  setUp(
    () => root = Directory(
      Directory.systemTemp
          .createTempSync('npm cache café ')
          .resolveSymbolicLinksSync(),
    ),
  );
  tearDown(() => root.deleteSync(recursive: true));
  Future<Map> run(String body) async {
    final f = await npmNativeFixture(root, 'tar.gz');
    final descriptor = {
      'schema_version': 1,
      'version': '1.2.3',
      'source': f.identity['source'],
      'targets': {
        for (final target in ['linux-x64', 'macos-arm64', 'windows-x64'])
          target: {...f.pin, 'url': 'https://example.test/$target'},
      },
    };
    final result = await Process.run(
      Platform.environment['ARCHWAY_TEST_NODE'] ?? 'node',
      [
        '-e',
        '''
const fs=require('node:fs/promises'),path=require('node:path'),assert=require('node:assert/strict');
const{acquireNative}=require(process.argv[1]);
const [descriptor,archive,cache]=JSON.parse(process.argv[2]);
const parent=path.join(cache,'1.2.3','linux-x64');
const key=path.join(parent,descriptor.targets['linux-x64'].sha256);
let requests=0;
const download=async(url,out)=>{requests++;assert.equal(url.href,'https://example.test/linux-x64');await fs.copyFile(archive,out,1);};
const acquire=(fetch=download)=>acquireNative(descriptor,'linux-x64',cache,fetch);
(async()=>{$body})().catch(e=>{console.error(e);process.exitCode=1;});
''',
        p.absolute('tool/npm/cache.cjs'),
        jsonEncode([descriptor, f.archive.path, p.join(root.path, 'cache')]),
      ],
    );
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    return jsonDecode(result.stdout as String) as Map;
  }

  test('cold cache commits complete bytes and warm use is offline', () async {
    final value = await run('''
const first=await acquire();
const second=await acquire(()=>{throw Error('unexpected warm network');});
console.log(JSON.stringify({requests,same:first===second,bytes:[...await fs.readFile(second)],entries:await fs.readdir(parent)}));
''');
    expect(value['requests'], 1);
    expect(value['same'], true);
    expect(value['bytes'], [97, 98, 99]);
    expect(value['entries'], hasLength(2));
  });
  test('concurrent fills atomically retain one verified winner and clean only losers', () async {
    final value = await run('''
let release;const ready=new Promise(resolve=>release=resolve);
const fetch=async(url,out)=>{await download(url,out);if(requests===2)release();await ready;};
const results=await Promise.all([acquire(fetch),acquire(fetch)]);
console.log(JSON.stringify({requests,same:results[0]===results[1],bytes:[...await fs.readFile(results[0])],entries:await fs.readdir(parent)}));
''');
    expect(value['requests'], 2);
    expect(value['same'], true);
    expect(value['bytes'], [97, 98, 99]);
    expect(value['entries'], hasLength(2));
  });
  test('foreign keys and failed downloads never trigger repair or leave valid entries', () async {
    final value = await run('''
await fs.mkdir(parent,{recursive:true});
await fs.mkdir(key);await fs.writeFile(path.join(key,'sentinel'),'keep');
await assert.rejects(acquire(),/nonordinary/);
assert.equal(await fs.readFile(path.join(key,'sentinel'),'utf8'),'keep');
await fs.rm(key,{recursive:true}); // Fixture owns this deliberately foreign key.
await fs.writeFile(key,'../escape\u005cn');
await assert.rejects(acquire(),/publication record/);
assert.equal(await fs.readFile(key,'utf8'),'../escape\u005cn');
await fs.unlink(key);
await assert.rejects(acquire(async(url,out)=>{await fs.writeFile(out,'partial');throw Error('interrupted');}),/interrupted/);
console.log(JSON.stringify({requests,entries:await fs.readdir(parent)}));
''');
    expect(value['requests'], 0);
    expect(value['entries'], isEmpty);
  });
  test('warm corruption is refused without network or deletion', () async {
    final value = await run('''
const executable=await acquire();
await fs.writeFile(executable,'bad');
await assert.rejects(acquire(),/cached executable differs/);
assert.equal(await fs.readFile(executable,'utf8'),'bad');
console.log(JSON.stringify({requests,entries:await fs.readdir(parent)}));
''');
    expect(value['requests'], 1);
    expect(value['entries'], hasLength(2));
  });
  test(
    'publication record is strict ASCII and cannot alias a valid basename',
    () async {
      final value = await run('''
await acquire();
const record=await fs.readFile(key);
record[1]|=128;await fs.writeFile(key,record);
await assert.rejects(acquire(),/publication record/);
console.log(JSON.stringify({requests,unchanged:(await fs.readFile(key)).equals(record)}));
''');
      expect(value['requests'], 1);
      expect(value['unchanged'], true);
    },
  );
  test(
    'failed record write cleans the file created before publication',
    () async {
      final value = await run(r"""
const write=fs.writeFile,open=fs.open;
fs.writeFile=async function(name,...args){const result=await write.call(this,name,...args);if(String(name).includes('.archway-record-'))throw Error('injected record write failure');return result;};
fs.open=async function(name,...args){const handle=await open.call(this,name,...args);if(String(name).includes('.archway-record-')){const original=handle.writeFile.bind(handle);handle.writeFile=async data=>{await original(data);throw Error('injected record write failure');};}return handle;};
await assert.rejects(acquire(),/injected record write failure/);
console.log(JSON.stringify({requests,entries:await fs.readdir(parent)}));
""");
      expect(value['requests'], 1);
      expect(value['entries'], isEmpty);
    },
  );
}
