#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioHardwareService.h>
#import <CoreAudio/CoreAudio.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/IOMessage.h>
#import <IOKit/pwr_mgt/IOPM.h>
#import <dlfcn.h>

static NSString *statePath(void) {
    return [NSHomeDirectory()
        stringByAppendingPathComponent:
            @"Library/Application Support/LidAudioGuard/saved-audio-state.plist"];
}
static const NSInteger MediaRemoteCommandPause = 1;

typedef Boolean (*MRSendCommandFn)(NSInteger command, CFDictionaryRef options);

@interface LidAudioGuard : NSObject
@property(nonatomic) io_service_t rootDomain;
@property(nonatomic) IONotificationPortRef notificationPort;
@property(nonatomic) io_object_t notification;
@property(nonatomic) BOOL lidClosed;
@property(nonatomic) BOOL testMode;
@property(nonatomic, strong) NSMutableDictionary *savedState;
@property(nonatomic, strong) dispatch_source_t timer;
- (BOOL)start;
- (void)handlePowerMessage:(natural_t)messageType
                  argument:(void *)messageArgument;
- (void)audioHardwareChanged;
- (void)beginGuard;
- (void)restorePending;
- (void)printStatus;
- (BOOL)runTestCycle;
@end

static AudioObjectPropertyAddress propertyAddress(
    AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope,
    AudioObjectPropertyElement element) {
    AudioObjectPropertyAddress address = {
        .mSelector = selector,
        .mScope = scope,
        .mElement = element,
    };
    return address;
}

static BOOL propertyIsSettable(
    AudioObjectID objectID,
    AudioObjectPropertyAddress address) {
    if (!AudioObjectHasProperty(objectID, &address)) {
        return NO;
    }
    Boolean settable = false;
    return AudioObjectIsPropertySettable(
               objectID, &address, &settable) == noErr &&
           settable;
}

static BOOL getUInt32Property(
    AudioObjectID objectID,
    AudioObjectPropertyAddress address,
    UInt32 *value) {
    UInt32 size = sizeof(*value);
    return AudioObjectGetPropertyData(
               objectID, &address, 0, NULL, &size, value) == noErr;
}

static BOOL setUInt32Property(
    AudioObjectID objectID,
    AudioObjectPropertyAddress address,
    UInt32 value) {
    UInt32 size = sizeof(value);
    return AudioObjectSetPropertyData(
               objectID, &address, 0, NULL, size, &value) == noErr;
}

static BOOL getFloatProperty(
    AudioObjectID objectID,
    AudioObjectPropertyAddress address,
    Float32 *value) {
    UInt32 size = sizeof(*value);
    return AudioObjectGetPropertyData(
               objectID, &address, 0, NULL, &size, value) == noErr;
}

static BOOL setFloatProperty(
    AudioObjectID objectID,
    AudioObjectPropertyAddress address,
    Float32 value) {
    UInt32 size = sizeof(value);
    return AudioObjectSetPropertyData(
               objectID, &address, 0, NULL, size, &value) == noErr;
}

static NSString *copyStringProperty(
    AudioObjectID objectID,
    AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress address = propertyAddress(
        selector,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain);
    CFStringRef value = NULL;
    UInt32 size = sizeof(value);
    if (AudioObjectGetPropertyData(
            objectID, &address, 0, NULL, &size, &value) != noErr ||
        value == NULL) {
        return nil;
    }
    NSString *result = [(__bridge NSString *)value copy];
    CFRelease(value);
    return result;
}

static NSArray<NSNumber *> *copyAudioDevices(void) {
    AudioObjectPropertyAddress address = propertyAddress(
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(
            kAudioObjectSystemObject, &address, 0, NULL, &size) != noErr ||
        size == 0) {
        return @[];
    }

    AudioDeviceID *devices = malloc(size);
    if (devices == NULL) {
        return @[];
    }
    if (AudioObjectGetPropertyData(
            kAudioObjectSystemObject,
            &address,
            0,
            NULL,
            &size,
            devices) != noErr) {
        free(devices);
        return @[];
    }

    NSUInteger count = size / sizeof(AudioDeviceID);
    NSMutableArray<NSNumber *> *result =
        [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger index = 0; index < count; index++) {
        [result addObject:@(devices[index])];
    }
    free(devices);
    return result;
}

static UInt32 outputChannelCount(AudioDeviceID deviceID) {
    AudioObjectPropertyAddress address = propertyAddress(
        kAudioDevicePropertyStreamConfiguration,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(
            deviceID, &address, 0, NULL, &size) != noErr ||
        size < sizeof(AudioBufferList)) {
        return 0;
    }

    AudioBufferList *list = malloc(size);
    if (list == NULL) {
        return 0;
    }
    if (AudioObjectGetPropertyData(
            deviceID, &address, 0, NULL, &size, list) != noErr) {
        free(list);
        return 0;
    }

    UInt32 channels = 0;
    for (UInt32 index = 0; index < list->mNumberBuffers; index++) {
        channels += list->mBuffers[index].mNumberChannels;
    }
    free(list);
    return channels;
}

static AudioDeviceID defaultDevice(
    AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress address = propertyAddress(
        selector,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain);
    AudioDeviceID deviceID = kAudioObjectUnknown;
    UInt32 size = sizeof(deviceID);
    if (AudioObjectGetPropertyData(
            kAudioObjectSystemObject,
            &address,
            0,
            NULL,
            &size,
            &deviceID) != noErr) {
        return kAudioObjectUnknown;
    }
    return deviceID;
}

static BOOL setDefaultDevice(
    AudioObjectPropertySelector selector,
    AudioDeviceID deviceID) {
    AudioObjectPropertyAddress address = propertyAddress(
        selector,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain);
    UInt32 size = sizeof(deviceID);
    return propertyIsSettable(kAudioObjectSystemObject, address) &&
           AudioObjectSetPropertyData(
               kAudioObjectSystemObject,
               &address,
               0,
               NULL,
               size,
               &deviceID) == noErr;
}

static NSDictionary *snapshotForDevice(AudioDeviceID deviceID) {
    UInt32 channels = outputChannelCount(deviceID);
    if (channels == 0) {
        return nil;
    }

    NSString *uid = copyStringProperty(
        deviceID, kAudioDevicePropertyDeviceUID);
    if (uid.length == 0) {
        return nil;
    }
    NSString *name = copyStringProperty(
        deviceID, kAudioObjectPropertyName) ?: uid;
    NSMutableDictionary *snapshot = [@{
        @"uid": uid,
        @"name": name,
        @"channels": @(channels),
    } mutableCopy];

    AudioObjectPropertyAddress mainMute = propertyAddress(
        kAudioDevicePropertyMute,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain);
    UInt32 mute = 0;
    if (propertyIsSettable(deviceID, mainMute) &&
        getUInt32Property(deviceID, mainMute, &mute)) {
        snapshot[@"strategy"] = @"main-mute";
        snapshot[@"mute"] = @(mute);
        return snapshot;
    }

    NSMutableDictionary *channelMutes = [NSMutableDictionary dictionary];
    for (UInt32 channel = 1; channel <= channels; channel++) {
        AudioObjectPropertyAddress address = propertyAddress(
            kAudioDevicePropertyMute,
            kAudioDevicePropertyScopeOutput,
            channel);
        UInt32 value = 0;
        if (propertyIsSettable(deviceID, address) &&
            getUInt32Property(deviceID, address, &value)) {
            channelMutes[[NSString stringWithFormat:@"%u", channel]] =
                @(value);
        }
    }
    if (channelMutes.count == channels) {
        snapshot[@"strategy"] = @"channel-mutes";
        snapshot[@"mutes"] = channelMutes;
        return snapshot;
    }

    AudioObjectPropertyAddress virtualVolume = propertyAddress(
        kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain);
    Float32 volume = 0;
    if (propertyIsSettable(deviceID, virtualVolume) &&
        getFloatProperty(deviceID, virtualVolume, &volume)) {
        snapshot[@"strategy"] = @"virtual-volume";
        snapshot[@"volume"] = @(volume);
        return snapshot;
    }

    AudioObjectPropertyAddress mainVolume = propertyAddress(
        kAudioDevicePropertyVolumeScalar,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain);
    if (propertyIsSettable(deviceID, mainVolume) &&
        getFloatProperty(deviceID, mainVolume, &volume)) {
        snapshot[@"strategy"] = @"main-volume";
        snapshot[@"volume"] = @(volume);
        return snapshot;
    }

    NSMutableDictionary *channelVolumes = [NSMutableDictionary dictionary];
    for (UInt32 channel = 1; channel <= channels; channel++) {
        AudioObjectPropertyAddress address = propertyAddress(
            kAudioDevicePropertyVolumeScalar,
            kAudioDevicePropertyScopeOutput,
            channel);
        Float32 value = 0;
        if (propertyIsSettable(deviceID, address) &&
            getFloatProperty(deviceID, address, &value)) {
            channelVolumes[[NSString stringWithFormat:@"%u", channel]] =
                @(value);
        }
    }
    if (channelVolumes.count == channels) {
        snapshot[@"strategy"] = @"channel-volumes";
        snapshot[@"volumes"] = channelVolumes;
        return snapshot;
    }

    snapshot[@"strategy"] = @"unavailable";
    return snapshot;
}

static BOOL applyMutedState(
    AudioDeviceID deviceID,
    NSDictionary *snapshot) {
    NSString *strategy = snapshot[@"strategy"];
    if ([strategy isEqualToString:@"main-mute"]) {
        AudioObjectPropertyAddress address = propertyAddress(
            kAudioDevicePropertyMute,
            kAudioDevicePropertyScopeOutput,
            kAudioObjectPropertyElementMain);
        return setUInt32Property(deviceID, address, 1);
    }
    if ([strategy isEqualToString:@"channel-mutes"]) {
        __block BOOL success = YES;
        [snapshot[@"mutes"] enumerateKeysAndObjectsUsingBlock:
            ^(NSString *element, NSNumber *value, BOOL *stop) {
                (void)value;
                (void)stop;
                AudioObjectPropertyAddress address = propertyAddress(
                    kAudioDevicePropertyMute,
                    kAudioDevicePropertyScopeOutput,
                    element.intValue);
                success = setUInt32Property(deviceID, address, 1) &&
                          success;
            }];
        return success;
    }
    if ([strategy isEqualToString:@"virtual-volume"]) {
        AudioObjectPropertyAddress address = propertyAddress(
            kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            kAudioDevicePropertyScopeOutput,
            kAudioObjectPropertyElementMain);
        return setFloatProperty(deviceID, address, 0);
    }
    if ([strategy isEqualToString:@"main-volume"]) {
        AudioObjectPropertyAddress address = propertyAddress(
            kAudioDevicePropertyVolumeScalar,
            kAudioDevicePropertyScopeOutput,
            kAudioObjectPropertyElementMain);
        return setFloatProperty(deviceID, address, 0);
    }
    if ([strategy isEqualToString:@"channel-volumes"]) {
        __block BOOL success = YES;
        [snapshot[@"volumes"] enumerateKeysAndObjectsUsingBlock:
            ^(NSString *element, NSNumber *value, BOOL *stop) {
                (void)value;
                (void)stop;
                AudioObjectPropertyAddress address = propertyAddress(
                    kAudioDevicePropertyVolumeScalar,
                    kAudioDevicePropertyScopeOutput,
                    element.intValue);
                success = setFloatProperty(deviceID, address, 0) &&
                          success;
            }];
        return success;
    }
    return NO;
}

static BOOL restoreDeviceState(
    AudioDeviceID deviceID,
    NSDictionary *snapshot) {
    NSString *strategy = snapshot[@"strategy"];
    if ([strategy isEqualToString:@"main-mute"]) {
        AudioObjectPropertyAddress address = propertyAddress(
            kAudioDevicePropertyMute,
            kAudioDevicePropertyScopeOutput,
            kAudioObjectPropertyElementMain);
        return setUInt32Property(
            deviceID, address, [snapshot[@"mute"] unsignedIntValue]);
    }
    if ([strategy isEqualToString:@"channel-mutes"]) {
        __block BOOL success = YES;
        [snapshot[@"mutes"] enumerateKeysAndObjectsUsingBlock:
            ^(NSString *element, NSNumber *value, BOOL *stop) {
                (void)stop;
                AudioObjectPropertyAddress address = propertyAddress(
                    kAudioDevicePropertyMute,
                    kAudioDevicePropertyScopeOutput,
                    element.intValue);
                success = setUInt32Property(
                              deviceID,
                              address,
                              value.unsignedIntValue) &&
                          success;
            }];
        return success;
    }
    if ([strategy isEqualToString:@"virtual-volume"]) {
        AudioObjectPropertyAddress address = propertyAddress(
            kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            kAudioDevicePropertyScopeOutput,
            kAudioObjectPropertyElementMain);
        return setFloatProperty(
            deviceID, address, [snapshot[@"volume"] floatValue]);
    }
    if ([strategy isEqualToString:@"main-volume"]) {
        AudioObjectPropertyAddress address = propertyAddress(
            kAudioDevicePropertyVolumeScalar,
            kAudioDevicePropertyScopeOutput,
            kAudioObjectPropertyElementMain);
        return setFloatProperty(
            deviceID, address, [snapshot[@"volume"] floatValue]);
    }
    if ([strategy isEqualToString:@"channel-volumes"]) {
        __block BOOL success = YES;
        [snapshot[@"volumes"] enumerateKeysAndObjectsUsingBlock:
            ^(NSString *element, NSNumber *value, BOOL *stop) {
                (void)stop;
                AudioObjectPropertyAddress address = propertyAddress(
                    kAudioDevicePropertyVolumeScalar,
                    kAudioDevicePropertyScopeOutput,
                    element.intValue);
                success = setFloatProperty(
                              deviceID, address, value.floatValue) &&
                          success;
            }];
        return success;
    }
    return YES;
}

static BOOL deviceMatchesMutedState(
    AudioDeviceID deviceID,
    NSDictionary *snapshot) {
    NSString *strategy = snapshot[@"strategy"];
    if ([strategy isEqualToString:@"main-mute"]) {
        UInt32 value = 0;
        AudioObjectPropertyAddress address = propertyAddress(
            kAudioDevicePropertyMute,
            kAudioDevicePropertyScopeOutput,
            kAudioObjectPropertyElementMain);
        return getUInt32Property(deviceID, address, &value) && value == 1;
    }
    if ([strategy isEqualToString:@"channel-mutes"]) {
        for (NSString *element in snapshot[@"mutes"]) {
            UInt32 value = 0;
            AudioObjectPropertyAddress address = propertyAddress(
                kAudioDevicePropertyMute,
                kAudioDevicePropertyScopeOutput,
                element.intValue);
            if (!getUInt32Property(deviceID, address, &value) || value != 1) {
                return NO;
            }
        }
        return YES;
    }

    AudioObjectPropertySelector selector =
        [strategy isEqualToString:@"virtual-volume"]
            ? kAudioHardwareServiceDeviceProperty_VirtualMainVolume
            : kAudioDevicePropertyVolumeScalar;
    if ([strategy isEqualToString:@"virtual-volume"] ||
        [strategy isEqualToString:@"main-volume"]) {
        Float32 value = 1;
        AudioObjectPropertyAddress address = propertyAddress(
            selector,
            kAudioDevicePropertyScopeOutput,
            kAudioObjectPropertyElementMain);
        return getFloatProperty(deviceID, address, &value) &&
               value <= 0.0001f;
    }
    if ([strategy isEqualToString:@"channel-volumes"]) {
        for (NSString *element in snapshot[@"volumes"]) {
            Float32 value = 1;
            AudioObjectPropertyAddress address = propertyAddress(
                kAudioDevicePropertyVolumeScalar,
                kAudioDevicePropertyScopeOutput,
                element.intValue);
            if (!getFloatProperty(deviceID, address, &value) ||
                value > 0.0001f) {
                return NO;
            }
        }
        return YES;
    }
    return NO;
}

static BOOL deviceMatchesRestoredState(
    AudioDeviceID deviceID,
    NSDictionary *snapshot) {
    NSString *strategy = snapshot[@"strategy"];
    if ([strategy isEqualToString:@"main-mute"]) {
        UInt32 value = 0;
        AudioObjectPropertyAddress address = propertyAddress(
            kAudioDevicePropertyMute,
            kAudioDevicePropertyScopeOutput,
            kAudioObjectPropertyElementMain);
        return getUInt32Property(deviceID, address, &value) &&
               value == [snapshot[@"mute"] unsignedIntValue];
    }
    if ([strategy isEqualToString:@"channel-mutes"]) {
        for (NSString *element in snapshot[@"mutes"]) {
            UInt32 value = 0;
            AudioObjectPropertyAddress address = propertyAddress(
                kAudioDevicePropertyMute,
                kAudioDevicePropertyScopeOutput,
                element.intValue);
            if (!getUInt32Property(deviceID, address, &value) ||
                value != [snapshot[@"mutes"][element] unsignedIntValue]) {
                return NO;
            }
        }
        return YES;
    }

    AudioObjectPropertySelector selector =
        [strategy isEqualToString:@"virtual-volume"]
            ? kAudioHardwareServiceDeviceProperty_VirtualMainVolume
            : kAudioDevicePropertyVolumeScalar;
    if ([strategy isEqualToString:@"virtual-volume"] ||
        [strategy isEqualToString:@"main-volume"]) {
        Float32 value = 0;
        AudioObjectPropertyAddress address = propertyAddress(
            selector,
            kAudioDevicePropertyScopeOutput,
            kAudioObjectPropertyElementMain);
        return getFloatProperty(deviceID, address, &value) &&
               fabsf(value - [snapshot[@"volume"] floatValue]) <= 0.001f;
    }
    if ([strategy isEqualToString:@"channel-volumes"]) {
        for (NSString *element in snapshot[@"volumes"]) {
            Float32 value = 0;
            AudioObjectPropertyAddress address = propertyAddress(
                kAudioDevicePropertyVolumeScalar,
                kAudioDevicePropertyScopeOutput,
                element.intValue);
            if (!getFloatProperty(deviceID, address, &value) ||
                fabsf(
                    value -
                    [snapshot[@"volumes"][element] floatValue]) > 0.001f) {
                return NO;
            }
        }
        return YES;
    }
    return YES;
}

static BOOL copyClamshellState(io_service_t rootDomain) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(
        rootDomain,
        CFSTR(kAppleClamshellStateKey),
        kCFAllocatorDefault,
        0);
    BOOL closed = NO;
    if (value != NULL) {
        if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
            closed = CFBooleanGetValue((CFBooleanRef)value);
        } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
            int number = 0;
            CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &number);
            closed = number != 0;
        }
        CFRelease(value);
    }
    return closed;
}

static void logMessage(NSString *message) {
    NSLog(@"%@", message);
}

static BOOL pauseCurrentMedia(BOOL logSuccess) {
    void *handle = dlopen(
        "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
        RTLD_LAZY | RTLD_LOCAL);
    if (handle == NULL) {
        logMessage(@"Media pause skipped: MediaRemote unavailable");
        return NO;
    }
    MRSendCommandFn sendCommand = (MRSendCommandFn)dlsym(
        handle, "MRMediaRemoteSendCommand");
    BOOL accepted = NO;
    if (sendCommand != NULL) {
        accepted = sendCommand(MediaRemoteCommandPause, NULL);
        if (logSuccess || !accepted) {
            logMessage([NSString stringWithFormat:
                @"Pause command sent to current media service, accepted=%@",
                accepted ? @"yes" : @"no"]);
        }
    } else {
        logMessage(@"Media pause skipped: command symbol unavailable");
    }
    dlclose(handle);
    return accepted;
}

static void powerMessageCallback(
    void *refcon,
    io_service_t service,
    natural_t messageType,
    void *messageArgument) {
    (void)service;
    LidAudioGuard *guard = (__bridge LidAudioGuard *)refcon;
    [guard handlePowerMessage:messageType argument:messageArgument];
}

static OSStatus audioPropertyCallback(
    AudioObjectID objectID,
    UInt32 numberAddresses,
    const AudioObjectPropertyAddress addresses[],
    void *clientData) {
    (void)objectID;
    (void)numberAddresses;
    (void)addresses;
    LidAudioGuard *guard = (__bridge LidAudioGuard *)clientData;
    dispatch_async(dispatch_get_main_queue(), ^{
        [guard audioHardwareChanged];
    });
    return noErr;
}

@implementation LidAudioGuard

- (instancetype)init {
    self = [super init];
    if (self) {
        _rootDomain = IO_OBJECT_NULL;
        _notificationPort = NULL;
        _notification = IO_OBJECT_NULL;
        [self loadSavedState];
    }
    return self;
}

- (void)dealloc {
    AudioObjectPropertyAddress devices = propertyAddress(
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain);
    AudioObjectPropertyAddress defaultOutput = propertyAddress(
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain);
    AudioObjectPropertyAddress defaultSystem = propertyAddress(
        kAudioHardwarePropertyDefaultSystemOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain);
    AudioObjectRemovePropertyListener(
        kAudioObjectSystemObject, &devices, audioPropertyCallback,
        (__bridge void *)self);
    AudioObjectRemovePropertyListener(
        kAudioObjectSystemObject, &defaultOutput, audioPropertyCallback,
        (__bridge void *)self);
    AudioObjectRemovePropertyListener(
        kAudioObjectSystemObject, &defaultSystem, audioPropertyCallback,
        (__bridge void *)self);

    if (_notification != IO_OBJECT_NULL) {
        IOObjectRelease(_notification);
    }
    if (_notificationPort != NULL) {
        IONotificationPortDestroy(_notificationPort);
    }
    if (_rootDomain != IO_OBJECT_NULL) {
        IOObjectRelease(_rootDomain);
    }
}

- (void)loadSavedState {
    NSDictionary *loaded =
        [NSDictionary dictionaryWithContentsOfFile:statePath()];
    if (![loaded isKindOfClass:[NSDictionary class]]) {
        self.savedState = nil;
        return;
    }
    self.savedState = [loaded mutableCopy];
    NSDictionary *devices = loaded[@"devices"];
    self.savedState[@"devices"] =
        [devices isKindOfClass:[NSDictionary class]]
            ? [devices mutableCopy]
            : [NSMutableDictionary dictionary];
}

- (NSMutableDictionary *)deviceStates {
    if (self.savedState == nil) {
        self.savedState = [@{
            @"version": @1,
            @"active": @NO,
            @"devices": [NSMutableDictionary dictionary],
        } mutableCopy];
    }
    NSMutableDictionary *devices = self.savedState[@"devices"];
    if (![devices isKindOfClass:[NSMutableDictionary class]]) {
        devices = [devices mutableCopy] ?: [NSMutableDictionary dictionary];
        self.savedState[@"devices"] = devices;
    }
    return devices;
}

- (BOOL)persistStateActive:(BOOL)active {
    NSMutableDictionary *devices = [self deviceStates];
    self.savedState[@"active"] = @(active);
    self.savedState[@"updatedAt"] = [NSDate date];
    BOOL hasSavedRoutes =
        self.savedState[@"defaultOutputUID"] != nil ||
        self.savedState[@"defaultSystemOutputUID"] != nil;
    if (devices.count == 0 && !active && !hasSavedRoutes) {
        self.savedState = nil;
        [[NSFileManager defaultManager]
            removeItemAtPath:statePath()
            error:nil];
        return YES;
    }
    BOOL written = [self.savedState
        writeToFile:statePath()
        atomically:YES];
    if (!written) {
        logMessage(@"Failed to persist saved audio state");
    }
    return written;
}

- (NSDictionary<NSString *, NSNumber *> *)currentOutputDevicesByUID {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSNumber *number in copyAudioDevices()) {
        AudioDeviceID deviceID = number.unsignedIntValue;
        if (outputChannelCount(deviceID) == 0) {
            continue;
        }
        NSString *uid = copyStringProperty(
            deviceID, kAudioDevicePropertyDeviceUID);
        if (uid.length > 0) {
            result[uid] = number;
        }
    }
    return result;
}

- (void)beginGuard {
    BOOL wasActive = [self.savedState[@"active"] boolValue];
    if (self.savedState != nil &&
        !wasActive) {
        [self restorePending];
    }

    NSMutableDictionary *deviceStates = [self deviceStates];
    NSMutableSet<NSString *> *newDeviceStates = [NSMutableSet set];
    NSDictionary<NSString *, NSNumber *> *current =
        [self currentOutputDevicesByUID];
    BOOL addedState = NO;

    if (self.savedState[@"defaultOutputUID"] == nil) {
        AudioDeviceID deviceID = defaultDevice(
            kAudioHardwarePropertyDefaultOutputDevice);
        NSString *uid = copyStringProperty(
            deviceID, kAudioDevicePropertyDeviceUID);
        if (uid.length > 0) {
            self.savedState[@"defaultOutputUID"] = uid;
            addedState = YES;
        }
    }
    if (self.savedState[@"defaultSystemOutputUID"] == nil) {
        AudioDeviceID deviceID = defaultDevice(
            kAudioHardwarePropertyDefaultSystemOutputDevice);
        NSString *uid = copyStringProperty(
            deviceID, kAudioDevicePropertyDeviceUID);
        if (uid.length > 0) {
            self.savedState[@"defaultSystemOutputUID"] = uid;
            addedState = YES;
        }
    }

    for (NSString *uid in current) {
        if (deviceStates[uid] != nil) {
            continue;
        }
        AudioDeviceID deviceID = current[uid].unsignedIntValue;
        NSDictionary *snapshot = snapshotForDevice(deviceID);
        if (snapshot != nil) {
            deviceStates[uid] = snapshot;
            [newDeviceStates addObject:uid];
            addedState = YES;
        }
    }

    NSString *safeUID = self.savedState[@"safeOutputUID"];
    NSDictionary *safeSnapshot = safeUID != nil
        ? deviceStates[safeUID]
        : nil;
    if (safeUID == nil ||
        [safeSnapshot[@"strategy"] isEqualToString:@"unavailable"] ||
        current[safeUID] == nil) {
        safeUID = nil;
        NSDictionary *builtIn = deviceStates[@"BuiltInSpeakerDevice"];
        if (current[@"BuiltInSpeakerDevice"] != nil &&
            ![builtIn[@"strategy"] isEqualToString:@"unavailable"]) {
            safeUID = @"BuiltInSpeakerDevice";
        }
        if (safeUID == nil) {
            AudioDeviceID systemDevice = defaultDevice(
                kAudioHardwarePropertyDefaultSystemOutputDevice);
            NSString *systemUID = copyStringProperty(
                systemDevice, kAudioDevicePropertyDeviceUID);
            NSDictionary *systemSnapshot = deviceStates[systemUID];
            if (current[systemUID] != nil &&
                ![systemSnapshot[@"strategy"]
                    isEqualToString:@"unavailable"]) {
                safeUID = systemUID;
            }
        }
        if (safeUID == nil) {
            for (NSString *candidate in current) {
                NSDictionary *snapshot = deviceStates[candidate];
                if (![snapshot[@"strategy"]
                    isEqualToString:@"unavailable"]) {
                    safeUID = candidate;
                    break;
                }
            }
        }
        if (safeUID != nil) {
            self.savedState[@"safeOutputUID"] = safeUID;
            addedState = YES;
        }
    }

    if (addedState || ![self.savedState[@"active"] boolValue]) {
        if (![self persistStateActive:YES]) {
            logMessage(@"Guard not applied because state could not be saved");
            return;
        }
    }

    for (NSString *uid in current) {
        NSDictionary *snapshot = deviceStates[uid];
        if (snapshot == nil) {
            continue;
        }
        if ([snapshot[@"strategy"] isEqualToString:@"unavailable"]) {
            if ([newDeviceStates containsObject:uid]) {
                logMessage([NSString stringWithFormat:
                    @"Output %@ (%@): no direct mute control; protected by safe routing",
                    snapshot[@"name"],
                    uid]);
            }
            continue;
        }
        AudioDeviceID deviceID = current[uid].unsignedIntValue;
        BOOL muted = deviceMatchesMutedState(deviceID, snapshot) ||
                     applyMutedState(deviceID, snapshot);
        if ([newDeviceStates containsObject:uid] || !muted) {
            logMessage([NSString stringWithFormat:
                @"Output %@ (%@): strategy=%@, muted=%@",
                snapshot[@"name"],
                uid,
                snapshot[@"strategy"],
                muted ? @"yes" : @"no"]);
        }
    }

    NSNumber *safeDevice = safeUID != nil ? current[safeUID] : nil;
    if (safeDevice != nil) {
        AudioDeviceID deviceID = safeDevice.unsignedIntValue;
        BOOL appAlreadyRouted =
            defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) ==
            deviceID;
        BOOL systemAlreadyRouted =
            defaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice) ==
            deviceID;
        BOOL appRouted = appAlreadyRouted || setDefaultDevice(
            kAudioHardwarePropertyDefaultOutputDevice, deviceID);
        BOOL systemRouted = systemAlreadyRouted || setDefaultDevice(
            kAudioHardwarePropertyDefaultSystemOutputDevice, deviceID);
        if (!appAlreadyRouted || !systemAlreadyRouted ||
            !appRouted || !systemRouted) {
            logMessage([NSString stringWithFormat:
                @"Safe output %@: appRoute=%@, systemRoute=%@",
                deviceStates[safeUID][@"name"],
                appRouted ? @"yes" : @"no",
                systemRouted ? @"yes" : @"no"]);
        }
    } else if (!wasActive || addedState) {
        logMessage(@"No controllable safe output device is available");
    }
}

- (void)restorePending {
    if (self.savedState == nil) {
        return;
    }

    NSMutableDictionary *deviceStates = [self deviceStates];
    NSDictionary<NSString *, NSNumber *> *current =
        [self currentOutputDevicesByUID];
    BOOL changed = [self.savedState[@"active"] boolValue];

    NSString *appOutputUID = self.savedState[@"defaultOutputUID"];
    NSNumber *appOutput = current[appOutputUID];
    if (appOutput != nil &&
        setDefaultDevice(
            kAudioHardwarePropertyDefaultOutputDevice,
            appOutput.unsignedIntValue)) {
        [self.savedState removeObjectForKey:@"defaultOutputUID"];
        changed = YES;
        logMessage([NSString stringWithFormat:
            @"Default output restored to %@", appOutputUID]);
    }

    NSString *systemOutputUID =
        self.savedState[@"defaultSystemOutputUID"];
    NSNumber *systemOutput = current[systemOutputUID];
    if (systemOutput != nil &&
        setDefaultDevice(
            kAudioHardwarePropertyDefaultSystemOutputDevice,
            systemOutput.unsignedIntValue)) {
        [self.savedState removeObjectForKey:@"defaultSystemOutputUID"];
        changed = YES;
        logMessage([NSString stringWithFormat:
            @"System output restored to %@", systemOutputUID]);
    }
    if (self.savedState[@"safeOutputUID"] != nil) {
        [self.savedState removeObjectForKey:@"safeOutputUID"];
        changed = YES;
    }

    for (NSString *uid in [deviceStates.allKeys copy]) {
        NSNumber *number = current[uid];
        if (number == nil) {
            continue;
        }
        NSDictionary *snapshot = deviceStates[uid];
        BOOL restored = restoreDeviceState(
            number.unsignedIntValue, snapshot);
        logMessage([NSString stringWithFormat:
            @"Output %@ (%@): restored=%@",
            snapshot[@"name"],
            uid,
            restored ? @"yes" : @"no"]);
        if (restored) {
            [deviceStates removeObjectForKey:uid];
            changed = YES;
        }
    }
    if (changed) {
        [self persistStateActive:NO];
    }
}

- (void)transitionToClosed:(BOOL)closed reason:(NSString *)reason {
    if (closed == self.lidClosed) {
        if (closed) {
            [self beginGuard];
        }
        return;
    }
    self.lidClosed = closed;
    if (closed) {
        [self beginGuard];
        if (!self.testMode) {
            pauseCurrentMedia(YES);
        }
    } else {
        [self restorePending];
    }
    logMessage([NSString stringWithFormat:
        @"Lid transitioned to %@ (%@)",
        closed ? @"closed" : @"open",
        reason]);
}

- (void)handlePowerMessage:(natural_t)messageType
                  argument:(void *)messageArgument {
    @autoreleasepool {
        if (messageType != kIOPMMessageClamshellStateChange) {
            return;
        }
        uintptr_t flags = (uintptr_t)messageArgument;
        BOOL closed = (flags & kClamshellStateBit) != 0;
        [self transitionToClosed:closed reason:@"IOKit notification"];
        logMessage([NSString stringWithFormat:
            @"Clamshell causes sleep=%@",
            (flags & kClamshellSleepBit) ? @"yes" : @"no"]);
    }
}

- (void)audioHardwareChanged {
    if (self.lidClosed) {
        [self beginGuard];
        if (!self.testMode) {
            pauseCurrentMedia(NO);
        }
    } else {
        [self restorePending];
    }
}

- (void)poll {
    BOOL actualClosed = copyClamshellState(self.rootDomain);
    if (actualClosed != self.lidClosed) {
        [self transitionToClosed:actualClosed reason:@"state poll"];
    } else if (actualClosed) {
        [self beginGuard];
        if (!self.testMode) {
            pauseCurrentMedia(NO);
        }
    } else if (self.savedState != nil) {
        [self restorePending];
    }
}

- (BOOL)registerAudioListeners {
    AudioObjectPropertyAddress devices = propertyAddress(
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain);
    AudioObjectPropertyAddress defaultOutput = propertyAddress(
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain);
    AudioObjectPropertyAddress defaultSystem = propertyAddress(
        kAudioHardwarePropertyDefaultSystemOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain);
    OSStatus first = AudioObjectAddPropertyListener(
        kAudioObjectSystemObject,
        &devices,
        audioPropertyCallback,
        (__bridge void *)self);
    OSStatus second = AudioObjectAddPropertyListener(
        kAudioObjectSystemObject,
        &defaultOutput,
        audioPropertyCallback,
        (__bridge void *)self);
    OSStatus third = AudioObjectAddPropertyListener(
        kAudioObjectSystemObject,
        &defaultSystem,
        audioPropertyCallback,
        (__bridge void *)self);
    return first == noErr && second == noErr && third == noErr;
}

- (BOOL)start {
    self.rootDomain = IOServiceGetMatchingService(
        kIOMainPortDefault,
        IOServiceMatching("IOPMrootDomain"));
    if (self.rootDomain == IO_OBJECT_NULL) {
        logMessage(@"Unable to find IOPMrootDomain");
        return NO;
    }
    self.lidClosed = copyClamshellState(self.rootDomain);

    self.notificationPort = IONotificationPortCreate(kIOMainPortDefault);
    if (self.notificationPort == NULL) {
        logMessage(@"Unable to create IOKit notification port");
        return NO;
    }
    CFRunLoopSourceRef source =
        IONotificationPortGetRunLoopSource(self.notificationPort);
    CFRunLoopAddSource(
        CFRunLoopGetMain(), source, kCFRunLoopDefaultMode);
    kern_return_t registration = IOServiceAddInterestNotification(
        self.notificationPort,
        self.rootDomain,
        kIOGeneralInterest,
        powerMessageCallback,
        (__bridge void *)self,
        &_notification);
    if (registration != KERN_SUCCESS) {
        logMessage([NSString stringWithFormat:
            @"Unable to register clamshell notification: 0x%08x",
            registration]);
        return NO;
    }
    if (![self registerAudioListeners]) {
        logMessage(@"Unable to register all CoreAudio listeners");
        return NO;
    }

    self.timer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(
        self.timer,
        dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
        5 * NSEC_PER_SEC,
        250 * NSEC_PER_MSEC);
    __weak LidAudioGuard *weakSelf = self;
    dispatch_source_set_event_handler(self.timer, ^{
        [weakSelf poll];
    });
    dispatch_resume(self.timer);

    if (self.lidClosed) {
        [self beginGuard];
        pauseCurrentMedia(YES);
    } else {
        [self restorePending];
    }
    logMessage([NSString stringWithFormat:
        @"Lid Audio Guard started; lid=%@",
        self.lidClosed ? @"closed" : @"open"]);
    return YES;
}

- (void)printStatus {
    BOOL closed = self.rootDomain != IO_OBJECT_NULL
        ? copyClamshellState(self.rootDomain)
        : NO;
    printf("lid=%s\n", closed ? "closed" : "open");
    printf("savedState=%s\n",
           self.savedState != nil ? "present" : "none");

    AudioDeviceID appDefault = defaultDevice(
        kAudioHardwarePropertyDefaultOutputDevice);
    AudioDeviceID systemDefault = defaultDevice(
        kAudioHardwarePropertyDefaultSystemOutputDevice);
    for (NSNumber *number in copyAudioDevices()) {
        AudioDeviceID deviceID = number.unsignedIntValue;
        UInt32 channels = outputChannelCount(deviceID);
        if (channels == 0) {
            continue;
        }
        NSDictionary *snapshot = snapshotForDevice(deviceID);
        NSString *name = snapshot[@"name"] ?: @"<unknown>";
        NSString *uid = snapshot[@"uid"] ?: @"<unknown>";
        NSString *strategy = snapshot[@"strategy"] ?: @"unavailable";
        NSMutableArray *roles = [NSMutableArray array];
        if (deviceID == appDefault) {
            [roles addObject:@"default-output"];
        }
        if (deviceID == systemDefault) {
            [roles addObject:@"system-output"];
        }
        NSString *role = roles.count > 0
            ? [roles componentsJoinedByString:@","]
            : @"other";
        printf("device=%s | uid=%s | channels=%u | control=%s | role=%s\n",
               name.UTF8String,
               uid.UTF8String,
               channels,
               strategy.UTF8String,
               role.UTF8String);
    }
}

- (BOOL)runTestCycle {
    if (copyClamshellState(self.rootDomain)) {
        fputs("Refusing test cycle while lid is closed\n", stderr);
        return NO;
    }
    self.testMode = YES;
    [self restorePending];
    self.lidClosed = NO;
    [self transitionToClosed:YES reason:@"validation cycle"];

    NSDictionary *snapshots =
        [[self deviceStates] copy];
    NSString *originalAppOutput =
        [self.savedState[@"defaultOutputUID"] copy];
    NSString *originalSystemOutput =
        [self.savedState[@"defaultSystemOutputUID"] copy];
    NSString *safeUID = [self.savedState[@"safeOutputUID"] copy];
    NSDictionary<NSString *, NSNumber *> *current =
        [self currentOutputDevicesByUID];
    BOOL muted = YES;
    for (NSString *uid in snapshots) {
        NSNumber *number = current[uid];
        NSDictionary *snapshot = snapshots[uid];
        if ([snapshot[@"strategy"] isEqualToString:@"unavailable"]) {
            continue;
        }
        BOOL deviceMuted = number != nil &&
            deviceMatchesMutedState(number.unsignedIntValue, snapshot);
        printf("mute-check=%s | device=%s\n",
               deviceMuted ? "pass" : "fail",
               [snapshot[@"name"] UTF8String]);
        muted = deviceMuted && muted;
    }

    AudioDeviceID appDevice = defaultDevice(
        kAudioHardwarePropertyDefaultOutputDevice);
    AudioDeviceID systemDevice = defaultDevice(
        kAudioHardwarePropertyDefaultSystemOutputDevice);
    NSString *appUID = copyStringProperty(
        appDevice, kAudioDevicePropertyDeviceUID);
    NSString *systemUID = copyStringProperty(
        systemDevice, kAudioDevicePropertyDeviceUID);
    BOOL routesSafe =
        safeUID.length > 0 &&
        [appUID isEqualToString:safeUID] &&
        [systemUID isEqualToString:safeUID];
    printf("safe-route-check=%s | device=%s\n",
           routesSafe ? "pass" : "fail",
           safeUID.UTF8String ?: "<none>");
    muted = routesSafe && muted;

    BOOL stateSaved = [[NSFileManager defaultManager]
        fileExistsAtPath:statePath()];
    printf("state-save-check=%s\n", stateSaved ? "pass" : "fail");
    self.savedState = nil;
    [self loadSavedState];
    BOOL stateReloaded =
        [self.savedState[@"active"] boolValue] &&
        [self.savedState[@"devices"] count] > 0;
    printf("state-reload-check=%s\n",
           stateReloaded ? "pass" : "fail");
    muted = stateSaved && stateReloaded && muted;

    [self transitionToClosed:NO reason:@"validation cycle"];
    current = [self currentOutputDevicesByUID];
    BOOL restored = YES;
    for (NSString *uid in snapshots) {
        NSNumber *number = current[uid];
        NSDictionary *snapshot = snapshots[uid];
        if ([snapshot[@"strategy"] isEqualToString:@"unavailable"]) {
            continue;
        }
        BOOL deviceRestored = number != nil &&
            deviceMatchesRestoredState(number.unsignedIntValue, snapshot);
        printf("restore-check=%s | device=%s\n",
               deviceRestored ? "pass" : "fail",
               [snapshot[@"name"] UTF8String]);
        restored = deviceRestored && restored;
    }
    appDevice = defaultDevice(
        kAudioHardwarePropertyDefaultOutputDevice);
    systemDevice = defaultDevice(
        kAudioHardwarePropertyDefaultSystemOutputDevice);
    appUID = copyStringProperty(
        appDevice, kAudioDevicePropertyDeviceUID);
    systemUID = copyStringProperty(
        systemDevice, kAudioDevicePropertyDeviceUID);
    BOOL routesRestored =
        [appUID isEqualToString:originalAppOutput] &&
        [systemUID isEqualToString:originalSystemOutput];
    printf("route-restore-check=%s\n",
           routesRestored ? "pass" : "fail");
    restored = routesRestored && restored;
    BOOL stateCleared = ![[NSFileManager defaultManager]
        fileExistsAtPath:statePath()];
    printf("state-clear-check=%s\n",
           stateCleared ? "pass" : "fail");
    restored = stateCleared && restored;
    self.testMode = NO;
    return muted && restored;
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        LidAudioGuard *guard = [[LidAudioGuard alloc] init];
        guard.rootDomain = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain"));

        if (argc == 2 && strcmp(argv[1], "--status") == 0) {
            [guard printStatus];
            return 0;
        }
        if (argc == 2 && strcmp(argv[1], "--test-cycle") == 0) {
            return [guard runTestCycle] ? 0 : 7;
        }
        if (argc == 2 && strcmp(argv[1], "--mute-now") == 0) {
            [guard beginGuard];
            pauseCurrentMedia(YES);
            return 0;
        }
        if (argc == 2 && strcmp(argv[1], "--restore-now") == 0) {
            [guard restorePending];
            return 0;
        }
        if (argc != 1) {
            fputs(
                "Usage: lid-audio-guard "
                "[--status|--test-cycle|--mute-now|--restore-now]\n",
                stderr);
            return 64;
        }

        if (guard.rootDomain != IO_OBJECT_NULL) {
            IOObjectRelease(guard.rootDomain);
            guard.rootDomain = IO_OBJECT_NULL;
        }
        if (![guard start]) {
            return 1;
        }
        CFRunLoopRun();
    }
    return 0;
}
