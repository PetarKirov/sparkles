/**
NT native declarations the capability VFS's Windows backend needs and druntime
lacks: the `Nt*` file calls with a `RootDirectory`, their information classes,
and the status codes the backend classifies.
*/
module sparkles.event_horizon.sys.nt;

version (Windows):

public import core.sys.windows.ntdef : OBJECT_ATTRIBUTES, OBJ_CASE_INSENSITIVE, UNICODE_STRING;
public import core.sys.windows.winioctl : FSCTL_GET_REPARSE_POINT, FSCTL_SET_REPARSE_POINT;
public import core.sys.windows.winnt : DELETE, FILE_ADD_FILE, FILE_ADD_SUBDIRECTORY,
    FILE_APPEND_DATA, FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_NORMAL, FILE_ATTRIBUTE_READONLY,
    FILE_ATTRIBUTE_REPARSE_POINT, FILE_CREATE, FILE_DELETE_CHILD, FILE_DIRECTORY_FILE,
    FILE_LIST_DIRECTORY, FILE_NON_DIRECTORY_FILE, FILE_OPEN, FILE_OPEN_FOR_BACKUP_INTENT,
    FILE_OPEN_IF, FILE_OPEN_REPARSE_POINT, FILE_OVERWRITE, FILE_OVERWRITE_IF, FILE_READ_ATTRIBUTES,
    FILE_READ_DATA, FILE_READ_EA, FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE,
    FILE_SUPERSEDE, FILE_SYNCHRONOUS_IO_NONALERT, FILE_TRAVERSE, FILE_WRITE_ATTRIBUTES,
    FILE_WRITE_DATA, FILE_WRITE_EA, FILE_WRITE_THROUGH, IO_REPARSE_TAG_MOUNT_POINT,
    IO_REPARSE_TAG_SYMLINK, READ_CONTROL, SYNCHRONIZE;
public import core.sys.windows.windef : BOOL, DWORD, HANDLE, ULONG, USHORT, WCHAR;

pragma(lib, "ntdll");
pragma(lib, "advapi32");

alias NTSTATUS = int;

/// `IO_STATUS_BLOCK`.
struct IO_STATUS_BLOCK
{
    union
    {
        NTSTATUS Status;
        void* Pointer;
    }
    size_t Information;
}

extern (Windows) nothrow @nogc @system
{
    NTSTATUS NtCreateFile(HANDLE* FileHandle, ULONG DesiredAccess, OBJECT_ATTRIBUTES* ObjectAttributes,
        IO_STATUS_BLOCK* IoStatusBlock, long* AllocationSize, ULONG FileAttributes, ULONG ShareAccess,
        ULONG CreateDisposition, ULONG CreateOptions, void* EaBuffer, ULONG EaLength);
    NTSTATUS NtClose(HANDLE Handle);
    NTSTATUS NtQueryInformationFile(HANDLE FileHandle, IO_STATUS_BLOCK* IoStatusBlock,
        void* FileInformation, ULONG Length, int FileInformationClass);
    NTSTATUS NtSetInformationFile(HANDLE FileHandle, IO_STATUS_BLOCK* IoStatusBlock,
        void* FileInformation, ULONG Length, int FileInformationClass);
    NTSTATUS NtQueryDirectoryFile(HANDLE FileHandle, HANDLE Event, void* ApcRoutine,
        void* ApcContext, IO_STATUS_BLOCK* IoStatusBlock, void* FileInformation, ULONG Length,
        int FileInformationClass, BOOL ReturnSingleEntry, UNICODE_STRING* FileName,
        BOOL RestartScan);
    NTSTATUS NtFsControlFile(HANDLE FileHandle, HANDLE Event, void* ApcRoutine, void* ApcContext,
        IO_STATUS_BLOCK* IoStatusBlock, ULONG FsControlCode, void* InputBuffer,
        ULONG InputBufferLength, void* OutputBuffer, ULONG OutputBufferLength);
    ULONG RtlNtStatusToDosError(NTSTATUS Status);
}

// OBJECT_ATTRIBUTES.Attributes: refuse any reparse point on the way (VFN5).
enum ULONG OBJ_DONT_REPARSE = 0x00001000;

enum ULONG FILE_SHARE_ALL = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;

// Reparse tags
/// The name-surrogate bit: symbolic links and junctions (VFN7).
enum ULONG REPARSE_TAG_NAME_SURROGATE = 0x20000000;
enum ULONG SYMLINK_FLAG_RELATIVE = 1;

// Information classes
enum int FileBasicInformation = 4;
enum int FileStandardInformation = 5;
enum int FileRenameInformation = 10;
enum int FileDispositionInformation = 13;
enum int FileFullDirectoryInformation = 2;
enum int FileAttributeTagInformation = 35;
enum int FileDispositionInformationEx = 64;

struct FILE_BASIC_INFORMATION
{
    long CreationTime, LastAccessTime, LastWriteTime, ChangeTime;
    ULONG FileAttributes;
}

struct FILE_STANDARD_INFORMATION
{
    long AllocationSize, EndOfFile;
    ULONG NumberOfLinks;
    ubyte DeletePending, Directory;
}

struct FILE_ATTRIBUTE_TAG_INFORMATION
{
    ULONG FileAttributes;
    ULONG ReparseTag;
}

struct FILE_DISPOSITION_INFORMATION
{
    ubyte DeleteFile;
}

struct FILE_DISPOSITION_INFORMATION_EX
{
    ULONG Flags;
}

enum ULONG FILE_DISPOSITION_DELETE = 0x1;
enum ULONG FILE_DISPOSITION_POSIX_SEMANTICS = 0x2;
enum ULONG FILE_DISPOSITION_IGNORE_READONLY_ATTRIBUTE = 0x10;

/// `FILE_RENAME_INFORMATION` with its name inline.
struct FILE_RENAME_INFORMATION
{
    ubyte ReplaceIfExists;
    HANDLE RootDirectory;
    ULONG FileNameLength;
    WCHAR[256] FileName;
}

/// `FILE_FULL_DIR_INFORMATION`; `EaSize` holds the reparse tag of a reparse point.
struct FILE_FULL_DIR_INFORMATION
{
    ULONG NextEntryOffset;
    ULONG FileIndex;
    long CreationTime, LastAccessTime, LastWriteTime, ChangeTime, EndOfFile, AllocationSize;
    ULONG FileAttributes;
    ULONG FileNameLength;
    ULONG EaSize;
    WCHAR[1] FileName;
}

// NTSTATUS values
enum NTSTATUS STATUS_SUCCESS = 0;
enum NTSTATUS STATUS_NO_MORE_FILES = cast(NTSTATUS) 0x80000006;
enum NTSTATUS STATUS_BUFFER_OVERFLOW = cast(NTSTATUS) 0x80000005;
enum NTSTATUS STATUS_INVALID_INFO_CLASS = cast(NTSTATUS) 0xC0000003;
enum NTSTATUS STATUS_INVALID_PARAMETER = cast(NTSTATUS) 0xC000000D;
enum NTSTATUS STATUS_NO_SUCH_FILE = cast(NTSTATUS) 0xC000000F;
enum NTSTATUS STATUS_ACCESS_DENIED = cast(NTSTATUS) 0xC0000022;
enum NTSTATUS STATUS_BUFFER_TOO_SMALL = cast(NTSTATUS) 0xC0000023;
enum NTSTATUS STATUS_OBJECT_NAME_INVALID = cast(NTSTATUS) 0xC0000033;
enum NTSTATUS STATUS_OBJECT_NAME_NOT_FOUND = cast(NTSTATUS) 0xC0000034;
enum NTSTATUS STATUS_OBJECT_NAME_COLLISION = cast(NTSTATUS) 0xC0000035;
enum NTSTATUS STATUS_OBJECT_PATH_NOT_FOUND = cast(NTSTATUS) 0xC000003A;
enum NTSTATUS STATUS_SHARING_VIOLATION = cast(NTSTATUS) 0xC0000043;
enum NTSTATUS STATUS_DELETE_PENDING = cast(NTSTATUS) 0xC0000056;
enum NTSTATUS STATUS_NOT_SUPPORTED = cast(NTSTATUS) 0xC00000BB;
enum NTSTATUS STATUS_FILE_IS_A_DIRECTORY = cast(NTSTATUS) 0xC00000BA;
enum NTSTATUS STATUS_DIRECTORY_NOT_EMPTY = cast(NTSTATUS) 0xC0000101;
enum NTSTATUS STATUS_NOT_A_DIRECTORY = cast(NTSTATUS) 0xC0000103;
enum NTSTATUS STATUS_CANNOT_DELETE = cast(NTSTATUS) 0xC0000121;
enum NTSTATUS STATUS_FILE_DELETED = cast(NTSTATUS) 0xC0000123;
enum NTSTATUS STATUS_NOT_A_REPARSE_POINT = cast(NTSTATUS) 0xC0000275;
enum NTSTATUS STATUS_REPARSE_POINT_ENCOUNTERED = cast(NTSTATUS) 0xC000050B;
enum NTSTATUS STATUS_NAME_TOO_LONG = cast(NTSTATUS) 0xC0000106;

/// Whether `s` is a success or informational status.
bool ntSuccess(NTSTATUS s) @safe pure nothrow @nogc => s >= 0;
