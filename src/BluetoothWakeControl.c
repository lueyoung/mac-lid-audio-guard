#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <mach/mach_error.h>
#include <stdio.h>
#include <string.h>

static const CFStringRef kRemoteWakeKey = CFSTR("RemoteWakeEnabled");

static io_registry_entry_t find_controller(void) {
    CFMutableDictionaryRef matching =
        IOServiceMatching("IOBluetoothHCIController");
    if (matching == NULL) {
        return IO_OBJECT_NULL;
    }
    return IOServiceGetMatchingService(kIOMainPortDefault, matching);
}

static void print_value(CFTypeRef value) {
    if (value == NULL) {
        puts("RemoteWakeEnabled=<absent>");
        return;
    }
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
        printf(
            "RemoteWakeEnabled=%s\n",
            CFBooleanGetValue((CFBooleanRef)value) ? "true" : "false");
        return;
    }

    CFStringRef description = CFCopyDescription(value);
    char buffer[1024];
    if (description != NULL &&
        CFStringGetCString(
            description,
            buffer,
            sizeof(buffer),
            kCFStringEncodingUTF8)) {
        printf("RemoteWakeEnabled=%s\n", buffer);
    } else {
        puts("RemoteWakeEnabled=<unprintable>");
    }
    if (description != NULL) {
        CFRelease(description);
    }
}

static int parse_requested_value(const char *argument, Boolean *value) {
    if (strcmp(argument, "disable") == 0 ||
        strcmp(argument, "false") == 0 ||
        strcmp(argument, "0") == 0) {
        *value = false;
        return 0;
    }
    if (strcmp(argument, "enable") == 0 ||
        strcmp(argument, "true") == 0 ||
        strcmp(argument, "1") == 0) {
        *value = true;
        return 0;
    }
    return -1;
}

int main(int argc, char **argv) {
    if (argc > 2) {
        fputs(
            "Usage: bluetooth-wake-control "
            "[status|disable|enable|false|true]\n",
            stderr);
        return 64;
    }

    io_registry_entry_t controller = find_controller();
    if (controller == IO_OBJECT_NULL) {
        fputs("Could not find IOBluetoothHCIController\n", stderr);
        return 2;
    }

    CFTypeRef before = IORegistryEntryCreateCFProperty(
        controller,
        kRemoteWakeKey,
        kCFAllocatorDefault,
        0);
    print_value(before);
    if (before != NULL) {
        CFRelease(before);
    }

    if (argc == 1 || strcmp(argv[1], "status") == 0) {
        IOObjectRelease(controller);
        return 0;
    }

    Boolean requested = false;
    if (parse_requested_value(argv[1], &requested) != 0) {
        fputs(
            "Usage: bluetooth-wake-control "
            "[status|disable|enable|false|true]\n",
            stderr);
        IOObjectRelease(controller);
        return 64;
    }

    kern_return_t result = IORegistryEntrySetCFProperty(
        controller,
        kRemoteWakeKey,
        requested ? kCFBooleanTrue : kCFBooleanFalse);
    printf(
        "set-result=0x%08x (%s)\n",
        result,
        mach_error_string(result));

    CFTypeRef after = IORegistryEntryCreateCFProperty(
        controller,
        kRemoteWakeKey,
        kCFAllocatorDefault,
        0);
    print_value(after);
    if (after != NULL) {
        CFRelease(after);
    }

    IOObjectRelease(controller);
    return result == KERN_SUCCESS ? 0 : 1;
}

