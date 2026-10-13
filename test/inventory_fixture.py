"""Independent directory-entry classification for canned helper inventories."""


def inventory_kind(entry):
    metadata = entry.stat(follow_symlinks=False)
    if getattr(metadata, 'st_file_attributes', 0) & 0x400:
        # Dart 3.13.3 runtime/bin/file_win.cc: GetTypeAndAttributes.
        # All no-follow reparse points are links except IO_REPARSE_TAG_AF_UNIX.
        return 'other' if metadata.st_reparse_tag == 0x80000023 else 'symlink'
    return ('symlink' if entry.is_symlink() else
            'file' if entry.is_file(follow_symlinks=False) else
            'directory' if entry.is_dir(follow_symlinks=False) else 'other')
