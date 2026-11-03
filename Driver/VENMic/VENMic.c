// VENMic — a loopback AudioServerPlugIn that exposes "VEN Enhanced Mic".
//
// The VEN Audio Enhance app writes processed audio to the device's output side
// (WriteMix); any recording app reads it back from the input side (ReadInput).
// Audio passes through a ring buffer indexed by device sample time, and every
// frame is zeroed after it is read so the mic goes silent when the app stops.
//
// The device also publishes a custom property ('vcnt') holding the number of
// clients other than the VEN app that are currently running IO, so the app can
// open the physical mic only while someone is actually recording.

#include <CoreAudio/AudioServerPlugIn.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>

#define kDeviceName        "VEN Enhanced Mic"
#define kManufacturer      "VEN"
#define kDeviceUID         "VENEnhancedMic_UID"
#define kModelUID          "VENEnhancedMic_ModelUID"
#define kAppBundleID       "com.ven.audioenhance"
#define kChannels          2
#define kRingFrames        16384
#define kMaxClients        64
#define kPropClientCount   'vcnt'

enum {
    kObjectID_PlugIn       = kAudioObjectPlugInObject,
    kObjectID_Device       = 2,
    kObjectID_StreamInput  = 3,
    kObjectID_StreamOutput = 4,
};

static const Float64 kSampleRates[] = { 44100.0, 48000.0 };
#define kNumSampleRates (sizeof(kSampleRates) / sizeof(kSampleRates[0]))

// MARK: - State

static pthread_mutex_t          gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static AudioServerPlugInHostRef gHost = NULL;
static UInt32                   gRefCount = 0;

static Float64  gSampleRate = 48000.0;
static Float64  gHostTicksPerFrame = 0;
static UInt64   gIOCount = 0;
static UInt64   gAnchorHostTime = 0;
static UInt64   gNumberTimeStamps = 0;
static Boolean  gInputStreamActive = true;
static Boolean  gOutputStreamActive = true;

static float    gRing[kRingFrames * kChannels];

typedef struct {
    UInt32  clientID;
    Boolean isApp;
    Boolean running;
} ClientSlot;
static ClientSlot gClients[kMaxClients];
static UInt32     gNumClients = 0;
static _Atomic UInt32 gOtherRunningCount = 0;

static void UpdateHostTicksPerFrame(void) {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    Float64 hostClockFrequency = ((Float64)tb.denom / (Float64)tb.numer) * 1000000000.0;
    gHostTicksPerFrame = hostClockFrequency / gSampleRate;
}

static AudioStreamBasicDescription FormatForRate(Float64 rate) {
    AudioStreamBasicDescription f = {0};
    f.mSampleRate = rate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = sizeof(float) * kChannels;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = sizeof(float) * kChannels;
    f.mChannelsPerFrame = kChannels;
    f.mBitsPerChannel = 32;
    return f;
}

static Boolean IsSupportedRate(Float64 rate) {
    for (UInt32 i = 0; i < kNumSampleRates; i++) {
        if (kSampleRates[i] == rate) return true;
    }
    return false;
}

// Called with gStateMutex held.
static void RecountClients(void) {
    UInt32 count = 0;
    for (UInt32 i = 0; i < gNumClients; i++) {
        if (gClients[i].running && !gClients[i].isApp) count++;
    }
    UInt32 old = atomic_exchange(&gOtherRunningCount, count);
    if (old != count && gHost != NULL) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            AudioObjectPropertyAddress addr = { kPropClientCount, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
            gHost->PropertiesChanged(gHost, kObjectID_Device, 1, &addr);
        });
    }
}

static ClientSlot* FindClient(UInt32 clientID) {
    for (UInt32 i = 0; i < gNumClients; i++) {
        if (gClients[i].clientID == clientID) return &gClients[i];
    }
    return NULL;
}

// MARK: - Property access

// Writes a single value of `type` when outData is non-NULL; always reports the size.
#define RETURN_VALUE(type, expr) do { \
    if (outData != NULL) { \
        if (inDataSize < sizeof(type)) return kAudioHardwareBadPropertySizeError; \
        *(type*)outData = (expr); \
    } \
    *outDataSize = sizeof(type); \
    return kAudioHardwareNoError; \
} while (0)

static OSStatus ReturnObjectIDs(const AudioObjectID* ids, UInt32 count, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    if (outData == NULL) {
        *outDataSize = count * sizeof(AudioObjectID);
        return kAudioHardwareNoError;
    }
    UInt32 n = inDataSize / sizeof(AudioObjectID);
    if (n > count) n = count;
    memcpy(outData, ids, n * sizeof(AudioObjectID));
    *outDataSize = n * sizeof(AudioObjectID);
    return kAudioHardwareNoError;
}

static OSStatus GetPlugInProperty(const AudioObjectPropertyAddress* addr, UInt32 qualSize, const void* qual,
                                  UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    static const AudioObjectID devices[] = { kObjectID_Device };
    switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:     RETURN_VALUE(AudioClassID, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner:     RETURN_VALUE(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: RETURN_VALUE(CFStringRef, CFSTR(kManufacturer));
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
            return ReturnObjectIDs(devices, 1, inDataSize, outDataSize, outData);
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            AudioObjectID result = kAudioObjectUnknown;
            if (outData != NULL && qualSize == sizeof(CFStringRef) && qual != NULL) {
                CFStringRef uid = *(const CFStringRef*)qual;
                if (uid != NULL && CFStringCompare(uid, CFSTR(kDeviceUID), 0) == kCFCompareEqualTo) {
                    result = kObjectID_Device;
                }
            }
            RETURN_VALUE(AudioObjectID, result);
        }
        case kAudioPlugInPropertyResourceBundle: RETURN_VALUE(CFStringRef, CFSTR(""));
        default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetDeviceProperty(const AudioObjectPropertyAddress* addr, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:     RETURN_VALUE(AudioClassID, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner:     RETURN_VALUE(AudioObjectID, kObjectID_PlugIn);
        case kAudioObjectPropertyName:      RETURN_VALUE(CFStringRef, CFSTR(kDeviceName));
        case kAudioObjectPropertyManufacturer: RETURN_VALUE(CFStringRef, CFSTR(kManufacturer));
        case kAudioDevicePropertyDeviceUID: RETURN_VALUE(CFStringRef, CFSTR(kDeviceUID));
        case kAudioDevicePropertyModelUID:  RETURN_VALUE(CFStringRef, CFSTR(kModelUID));
        case kAudioDevicePropertyConfigurationApplication: RETURN_VALUE(CFStringRef, CFSTR(kAppBundleID));
        case kAudioDevicePropertyTransportType: RETURN_VALUE(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyClockDomain: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyDeviceIsAlive: RETURN_VALUE(UInt32, 1);
        case kAudioDevicePropertyDeviceIsRunning: {
            pthread_mutex_lock(&gStateMutex);
            UInt32 running = gIOCount > 0;
            pthread_mutex_unlock(&gStateMutex);
            RETURN_VALUE(UInt32, running);
        }
        // Selectable as the default input, never as an output, so it can't hijack system sound.
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            RETURN_VALUE(UInt32, addr->mScope == kAudioObjectPropertyScopeInput ? 1 : 0);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyLatency:   RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertySafetyOffset: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyIsHidden:  RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyZeroTimeStampPeriod: RETURN_VALUE(UInt32, kRingFrames);
        case kAudioDevicePropertyClockIsStable: RETURN_VALUE(UInt32, 1);
        case kAudioDevicePropertyNominalSampleRate: {
            pthread_mutex_lock(&gStateMutex);
            Float64 rate = gSampleRate;
            pthread_mutex_unlock(&gStateMutex);
            RETURN_VALUE(Float64, rate);
        }
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            if (outData == NULL) {
                *outDataSize = kNumSampleRates * sizeof(AudioValueRange);
                return kAudioHardwareNoError;
            }
            UInt32 n = inDataSize / sizeof(AudioValueRange);
            if (n > kNumSampleRates) n = kNumSampleRates;
            AudioValueRange* ranges = outData;
            for (UInt32 i = 0; i < n; i++) {
                ranges[i].mMinimum = kSampleRates[i];
                ranges[i].mMaximum = kSampleRates[i];
            }
            *outDataSize = n * sizeof(AudioValueRange);
            return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyRelatedDevices: {
            static const AudioObjectID related[] = { kObjectID_Device };
            return ReturnObjectIDs(related, 1, inDataSize, outDataSize, outData);
        }
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams: {
            static const AudioObjectID both[] = { kObjectID_StreamInput, kObjectID_StreamOutput };
            static const AudioObjectID input[] = { kObjectID_StreamInput };
            static const AudioObjectID output[] = { kObjectID_StreamOutput };
            switch (addr->mScope) {
                case kAudioObjectPropertyScopeInput:  return ReturnObjectIDs(input, 1, inDataSize, outDataSize, outData);
                case kAudioObjectPropertyScopeOutput: return ReturnObjectIDs(output, 1, inDataSize, outDataSize, outData);
                default:                              return ReturnObjectIDs(both, 2, inDataSize, outDataSize, outData);
            }
        }
        case kAudioObjectPropertyControlList:
            return ReturnObjectIDs(NULL, 0, inDataSize, outDataSize, outData);
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            if (outData != NULL) {
                if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                ((UInt32*)outData)[0] = 1;
                ((UInt32*)outData)[1] = 2;
            }
            *outDataSize = 2 * sizeof(UInt32);
            return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            UInt32 size = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + kChannels * sizeof(AudioChannelDescription));
            if (outData != NULL) {
                if (inDataSize < size) return kAudioHardwareBadPropertySizeError;
                AudioChannelLayout* layout = outData;
                memset(layout, 0, size);
                layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
                layout->mNumberChannelDescriptions = kChannels;
                layout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
                layout->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
            }
            *outDataSize = size;
            return kAudioHardwareNoError;
        }
        case kAudioObjectPropertyCustomPropertyInfoList: {
            if (outData != NULL) {
                if (inDataSize < sizeof(AudioServerPlugInCustomPropertyInfo)) return kAudioHardwareBadPropertySizeError;
                AudioServerPlugInCustomPropertyInfo* info = outData;
                info->mSelector = kPropClientCount;
                info->mPropertyDataType = kAudioServerPlugInCustomPropertyDataTypeCFPropertyList;
                info->mQualifierDataType = kAudioServerPlugInCustomPropertyDataTypeNone;
            }
            *outDataSize = sizeof(AudioServerPlugInCustomPropertyInfo);
            return kAudioHardwareNoError;
        }
        case kPropClientCount: {
            if (outData != NULL) {
                if (inDataSize < sizeof(CFPropertyListRef)) return kAudioHardwareBadPropertySizeError;
                SInt32 count = (SInt32)atomic_load(&gOtherRunningCount);
                *(CFPropertyListRef*)outData = CFNumberCreate(NULL, kCFNumberSInt32Type, &count);
            }
            *outDataSize = sizeof(CFPropertyListRef);
            return kAudioHardwareNoError;
        }
        default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetStreamProperty(AudioObjectID objectID, const AudioObjectPropertyAddress* addr,
                                  UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    Boolean isInput = objectID == kObjectID_StreamInput;
    switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:     RETURN_VALUE(AudioClassID, kAudioStreamClassID);
        case kAudioObjectPropertyOwner:     RETURN_VALUE(AudioObjectID, kObjectID_Device);
        case kAudioObjectPropertyName:      RETURN_VALUE(CFStringRef, isInput ? CFSTR("VEN Enhanced Mic In") : CFSTR("VEN Enhanced Mic Feed"));
        case kAudioObjectPropertyOwnedObjects: return ReturnObjectIDs(NULL, 0, inDataSize, outDataSize, outData);
        case kAudioStreamPropertyIsActive: {
            pthread_mutex_lock(&gStateMutex);
            UInt32 active = isInput ? gInputStreamActive : gOutputStreamActive;
            pthread_mutex_unlock(&gStateMutex);
            RETURN_VALUE(UInt32, active);
        }
        case kAudioStreamPropertyDirection: RETURN_VALUE(UInt32, isInput ? 1 : 0);
        case kAudioStreamPropertyTerminalType:
            RETURN_VALUE(UInt32, isInput ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeLine);
        case kAudioStreamPropertyStartingChannel: RETURN_VALUE(UInt32, 1);
        case kAudioStreamPropertyLatency: RETURN_VALUE(UInt32, 0);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            pthread_mutex_lock(&gStateMutex);
            Float64 rate = gSampleRate;
            pthread_mutex_unlock(&gStateMutex);
            RETURN_VALUE(AudioStreamBasicDescription, FormatForRate(rate));
        }
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            if (outData == NULL) {
                *outDataSize = kNumSampleRates * sizeof(AudioStreamRangedDescription);
                return kAudioHardwareNoError;
            }
            UInt32 n = inDataSize / sizeof(AudioStreamRangedDescription);
            if (n > kNumSampleRates) n = kNumSampleRates;
            AudioStreamRangedDescription* descs = outData;
            for (UInt32 i = 0; i < n; i++) {
                descs[i].mFormat = FormatForRate(kSampleRates[i]);
                descs[i].mSampleRateRange.mMinimum = kSampleRates[i];
                descs[i].mSampleRateRange.mMaximum = kSampleRates[i];
            }
            *outDataSize = n * sizeof(AudioStreamRangedDescription);
            return kAudioHardwareNoError;
        }
        default: return kAudioHardwareUnknownPropertyError;
    }
}

// outData == NULL means "report the size only"; HasProperty and GetPropertyDataSize use that mode.
static OSStatus GetProperty(AudioObjectID objectID, const AudioObjectPropertyAddress* addr, UInt32 qualSize, const void* qual,
                            UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    switch (objectID) {
        case kObjectID_PlugIn: return GetPlugInProperty(addr, qualSize, qual, inDataSize, outDataSize, outData);
        case kObjectID_Device: return GetDeviceProperty(addr, inDataSize, outDataSize, outData);
        case kObjectID_StreamInput:
        case kObjectID_StreamOutput: return GetStreamProperty(objectID, addr, inDataSize, outDataSize, outData);
        default: return kAudioHardwareBadObjectError;
    }
}

static void RequestSampleRate(Float64 rate) {
    if (gHost == NULL) return;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        gHost->RequestDeviceConfigurationChange(gHost, kObjectID_Device, (UInt64)rate, NULL);
    });
}

// MARK: - Driver interface

static HRESULT VEN_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG VEN_AddRef(void* inDriver);
static ULONG VEN_Release(void* inDriver);

static OSStatus VEN_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    gHost = inHost;
    pthread_mutex_lock(&gStateMutex);
    UpdateHostTicksPerFrame();
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus VEN_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo* ci, AudioObjectID* out) {
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus VEN_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID dev) {
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus VEN_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID dev, const AudioServerPlugInClientInfo* ci) {
    if (dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gNumClients < kMaxClients && FindClient(ci->mClientID) == NULL) {
        ClientSlot* slot = &gClients[gNumClients++];
        slot->clientID = ci->mClientID;
        slot->running = false;
        slot->isApp = ci->mBundleID != NULL &&
                      CFStringCompare(ci->mBundleID, CFSTR(kAppBundleID), 0) == kCFCompareEqualTo;
    }
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus VEN_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID dev, const AudioServerPlugInClientInfo* ci) {
    if (dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    for (UInt32 i = 0; i < gNumClients; i++) {
        if (gClients[i].clientID == ci->mClientID) {
            gClients[i] = gClients[--gNumClients];
            break;
        }
    }
    RecountClients();
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus VEN_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt64 action, void* info) {
    if (dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    Float64 rate = (Float64)action;
    if (!IsSupportedRate(rate)) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    gSampleRate = rate;
    UpdateHostTicksPerFrame();
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus VEN_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt64 action, void* info) {
    return kAudioHardwareNoError;
}

static Boolean VEN_HasProperty(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress* addr) {
    UInt32 size = 0;
    return GetProperty(obj, addr, 0, NULL, 0, &size, NULL) == kAudioHardwareNoError;
}

static OSStatus VEN_IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid,
                                       const AudioObjectPropertyAddress* addr, Boolean* outIsSettable) {
    UInt32 size = 0;
    OSStatus err = GetProperty(obj, addr, 0, NULL, 0, &size, NULL);
    if (err != kAudioHardwareNoError) return err;
    switch (addr->mSelector) {
        case kAudioDevicePropertyNominalSampleRate:
            *outIsSettable = obj == kObjectID_Device;
            break;
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outIsSettable = obj == kObjectID_StreamInput || obj == kObjectID_StreamOutput;
            break;
        default:
            *outIsSettable = false;
    }
    return kAudioHardwareNoError;
}

static OSStatus VEN_GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress* addr,
                                        UInt32 qualSize, const void* qual, UInt32* outDataSize) {
    return GetProperty(obj, addr, qualSize, qual, 0, outDataSize, NULL);
}

static OSStatus VEN_GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress* addr,
                                    UInt32 qualSize, const void* qual, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    if (outData == NULL) return kAudioHardwareIllegalOperationError;
    return GetProperty(obj, addr, qualSize, qual, inDataSize, outDataSize, outData);
}

static OSStatus VEN_SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress* addr,
                                    UInt32 qualSize, const void* qual, UInt32 inDataSize, const void* inData) {
    switch (addr->mSelector) {
        case kAudioDevicePropertyNominalSampleRate: {
            if (obj != kObjectID_Device) return kAudioHardwareUnknownPropertyError;
            if (inDataSize != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
            Float64 rate = *(const Float64*)inData;
            if (!IsSupportedRate(rate)) return kAudioHardwareIllegalOperationError;
            if (rate != gSampleRate) RequestSampleRate(rate);
            return kAudioHardwareNoError;
        }
        case kAudioStreamPropertyIsActive: {
            if (obj != kObjectID_StreamInput && obj != kObjectID_StreamOutput) return kAudioHardwareUnknownPropertyError;
            if (inDataSize != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            Boolean active = *(const UInt32*)inData != 0;
            pthread_mutex_lock(&gStateMutex);
            if (obj == kObjectID_StreamInput) gInputStreamActive = active; else gOutputStreamActive = active;
            pthread_mutex_unlock(&gStateMutex);
            AudioObjectPropertyAddress changed = { kAudioStreamPropertyIsActive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
            gHost->PropertiesChanged(gHost, obj, 1, &changed);
            return kAudioHardwareNoError;
        }
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            if (obj != kObjectID_StreamInput && obj != kObjectID_StreamOutput) return kAudioHardwareUnknownPropertyError;
            if (inDataSize != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
            const AudioStreamBasicDescription* f = inData;
            AudioStreamBasicDescription want = FormatForRate(f->mSampleRate);
            if (!IsSupportedRate(f->mSampleRate) || f->mFormatID != want.mFormatID || f->mChannelsPerFrame != want.mChannelsPerFrame ||
                f->mBitsPerChannel != want.mBitsPerChannel) {
                return kAudioDeviceUnsupportedFormatError;
            }
            if (f->mSampleRate != gSampleRate) RequestSampleRate(f->mSampleRate);
            return kAudioHardwareNoError;
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus VEN_StartIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 clientID) {
    if (dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gIOCount == 0) {
        gNumberTimeStamps = 0;
        gAnchorHostTime = mach_absolute_time();
        memset(gRing, 0, sizeof(gRing));
    }
    gIOCount++;
    ClientSlot* slot = FindClient(clientID);
    if (slot != NULL) slot->running = true;
    RecountClients();
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus VEN_StopIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 clientID) {
    if (dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gIOCount > 0) gIOCount--;
    ClientSlot* slot = FindClient(clientID);
    if (slot != NULL) slot->running = false;
    RecountClients();
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus VEN_GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 clientID,
                                     Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    pthread_mutex_lock(&gStateMutex);
    UInt64 now = mach_absolute_time();
    Float64 ticksPerPeriod = gHostTicksPerFrame * (Float64)kRingFrames;
    UInt64 nextTime = gAnchorHostTime + (UInt64)((Float64)(gNumberTimeStamps + 1) * ticksPerPeriod);
    if (nextTime <= now) gNumberTimeStamps++;
    *outSampleTime = (Float64)(gNumberTimeStamps * kRingFrames);
    *outHostTime = gAnchorHostTime + (UInt64)((Float64)gNumberTimeStamps * ticksPerPeriod);
    *outSeed = 1;
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus VEN_WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 clientID, UInt32 op,
                                      Boolean* outWillDo, Boolean* outWillDoInPlace) {
    *outWillDo = op == kAudioServerPlugInIOOperationReadInput || op == kAudioServerPlugInIOOperationWriteMix;
    *outWillDoInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus VEN_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 clientID, UInt32 op,
                                     UInt32 frames, const AudioServerPlugInIOCycleInfo* cycle) {
    return kAudioHardwareNoError;
}

static UInt32 RingIndex(Float64 sampleTime) {
    SInt64 t = (SInt64)sampleTime % kRingFrames;
    return (UInt32)(t < 0 ? t + kRingFrames : t);
}

static OSStatus VEN_DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, AudioObjectID stream, UInt32 clientID, UInt32 op,
                                  UInt32 frames, const AudioServerPlugInIOCycleInfo* cycle, void* mainBuffer, void* secondaryBuffer) {
    if (frames > kRingFrames) frames = kRingFrames;
    float* buf = mainBuffer;
    if (op == kAudioServerPlugInIOOperationWriteMix) {
        UInt32 start = RingIndex(cycle->mOutputTime.mSampleTime);
        UInt32 first = frames < kRingFrames - start ? frames : kRingFrames - start;
        memcpy(&gRing[start * kChannels], buf, first * kChannels * sizeof(float));
        memcpy(gRing, buf + first * kChannels, (frames - first) * kChannels * sizeof(float));
    } else if (op == kAudioServerPlugInIOOperationReadInput) {
        UInt32 start = RingIndex(cycle->mInputTime.mSampleTime);
        UInt32 first = frames < kRingFrames - start ? frames : kRingFrames - start;
        memcpy(buf, &gRing[start * kChannels], first * kChannels * sizeof(float));
        memcpy(buf + first * kChannels, gRing, (frames - first) * kChannels * sizeof(float));
        // Consume what was read so the mic falls silent if the app stops feeding it.
        memset(&gRing[start * kChannels], 0, first * kChannels * sizeof(float));
        memset(gRing, 0, (frames - first) * kChannels * sizeof(float));
    }
    return kAudioHardwareNoError;
}

static OSStatus VEN_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 clientID, UInt32 op,
                                   UInt32 frames, const AudioServerPlugInIOCycleInfo* cycle) {
    return kAudioHardwareNoError;
}

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    VEN_QueryInterface,
    VEN_AddRef,
    VEN_Release,
    VEN_Initialize,
    VEN_CreateDevice,
    VEN_DestroyDevice,
    VEN_AddDeviceClient,
    VEN_RemoveDeviceClient,
    VEN_PerformDeviceConfigurationChange,
    VEN_AbortDeviceConfigurationChange,
    VEN_HasProperty,
    VEN_IsPropertySettable,
    VEN_GetPropertyDataSize,
    VEN_GetPropertyData,
    VEN_SetPropertyData,
    VEN_StartIO,
    VEN_StopIO,
    VEN_GetZeroTimeStamp,
    VEN_WillDoIOOperation,
    VEN_BeginIOOperation,
    VEN_DoIOOperation,
    VEN_EndIOOperation,
};
static AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

static HRESULT VEN_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface) {
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gStateMutex);
        gRefCount++;
        pthread_mutex_unlock(&gStateMutex);
        *outInterface = gDriverRef;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

static ULONG VEN_AddRef(void* inDriver) {
    pthread_mutex_lock(&gStateMutex);
    ULONG count = ++gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

static ULONG VEN_Release(void* inDriver) {
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount > 0) gRefCount--;
    ULONG count = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

__attribute__((visibility("default")))
void* VENMic_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    if (CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) return gDriverRef;
    return NULL;
}
