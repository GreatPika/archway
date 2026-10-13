"""Portable regression for the Windows fault fixture's close-attempt logger.

This tests fixture bookkeeping using real POSIX descriptor consumption. It is
not Windows bridge execution; the CLI fault suite also runs a host-native mutant.
"""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.name == 'posix', 'Portable logger oracle uses POSIX descriptors')
class NativeFaultLogger(unittest.TestCase):
    def test_consumed_handle_retry_is_visible(self):
        fixture = (ROOT / 'test/native_fault_windows_fixture.c').read_text()
        function = fixture[fixture.index('static BOOL WINAPI fixture_close(HANDLE file) {'):]
        function = function[:function.index('static BOOL WINAPI fixture_information')]
        prelude = r'''
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
typedef int BOOL;
typedef int HANDLE;
typedef unsigned long DWORD;
typedef struct { unsigned long FileAttributes; } FILE_ATTRIBUTE_TAG_INFO;
#define WINAPI
#define FALSE 0
#define ERROR_INVALID_HANDLE 6
#define FileAttributeTagInfo 0
#define FILE_ATTRIBUTE_DIRECTORY 16
static HANDLE outputs[64];
static int output_count;
static DWORD last_error;
static DWORD GetLastError(void) { return last_error; }
static void SetLastError(DWORD error) { last_error = error; }
static BOOL CloseHandle(HANDLE file) { int result = close(file); last_error = result ? 6 : 0; return result == 0; }
static BOOL GetFileInformationByHandleEx(HANDLE file, int kind, FILE_ATTRIBUTE_TAG_INFO *info, size_t size) {
  (void)kind; (void)size; struct stat st;
  if (fstat(file, &st)) return 0;
  info->FileAttributes = S_ISDIR(st.st_mode) ? FILE_ATTRIBUTE_DIRECTORY : 0; return 1;
}
static int is_fault(const char *name) { return strcmp(name, "close") == 0; }
'''
        main = r'''
int main(int argc, char **argv) {
  if (argc != 2) return 10;
  int file = open(argv[1], O_CREAT | O_WRONLY, 0600);
  if (file < 0) return 11;
  outputs[output_count++] = file;
  if (fixture_close(file)) return 12;
  if (fixture_close(file)) return 13;
  return 0;
}
'''
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            source = base / 'logger.c'
            source.write_text(prelude + function + main)
            binary = base / 'logger'
            subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror',
                            str(source), '-o', str(binary)], check=True, capture_output=True)
            log = base / 'close.log'
            subprocess.run([str(binary), str(base / 'output')], check=True,
                           env={**os.environ, 'ARCHWAY_TEST_CLOSE_LOG': str(log)})
            self.assertEqual(log.read_text().splitlines(), ['file', 'invalid'])


if __name__ == '__main__':
    unittest.main()
