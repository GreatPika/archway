// Shared maintainer-only preparation program, also bound by receipt admission.
const npmNativePreparationProgram = r'''
const fs=require('node:fs');
const [owner,descriptor,target,cache,archive]=process.argv.slice(1);
require(owner).acquireNative(JSON.parse(fs.readFileSync(descriptor,'utf8')),target,cache,
  async(_,destination)=>fs.promises.copyFile(archive,destination,fs.constants.COPYFILE_EXCL)
).catch(error=>{console.error(error);process.exitCode=1});
''';
