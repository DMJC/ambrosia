#import "PipeWireBackend.h"

#include <pipewire/pipewire.h>
#include <pipewire/extensions/metadata.h>
#include <spa/param/props.h>
#include <spa/pod/builder.h>
#include <spa/pod/parser.h>

// Per-node entry with spa_hook members that need stable memory addresses.
typedef struct PWNodeEntry {
    uint32_t         node_id;
    struct pw_proxy *proxy;
    struct spa_hook  node_listener;
    BOOL             is_sink;
    void            *backend_ref; // __bridge, unsafe unretained
} PWNodeEntry;

// Forward declarations.
static void registry_global_cb(void *data, uint32_t id, uint32_t permissions,
                                const char *type, uint32_t version,
                                const struct spa_dict *props);
static void registry_global_remove_cb(void *data, uint32_t id);
static void node_param_cb(void *data, int seq, uint32_t id, uint32_t index,
                          uint32_t next, const struct spa_pod *param);

static const struct pw_registry_events registry_events = {
    .version       = PW_VERSION_REGISTRY_EVENTS,
    .global        = registry_global_cb,
    .global_remove = registry_global_remove_cb,
};

static const struct pw_node_events node_events = {
    .version = PW_VERSION_NODE_EVENTS,
    .param   = node_param_cb,
};

@interface PipeWireBackend () {
    struct pw_thread_loop *_threadLoop;
    struct pw_context     *_pwContext;
    struct pw_core        *_pwCore;
    struct pw_registry    *_pwRegistry;
    struct pw_proxy       *_metadataProxy;
    uint32_t               _metadataNodeId;
    struct spa_hook        _registryListener;
    // Keyed by node_id (NSNumber). Accessed only under _threadLoop lock.
    NSMutableDictionary<NSNumber *, NSValue *>  *_nodeEntries;
    // node_id → PW_KEY_NODE_NAME; used when setting the default device via metadata.
    NSMutableDictionary<NSNumber *, NSString *> *_nodeNames;
    // Node IDs of the currently-selected input and output device.
    uint32_t _selectedInputId;
    uint32_t _selectedOutputId;
}
@end

@implementation PipeWireBackend

- (NSArray<NSString *> *)inputDeviceNames  { return _inputDeviceNames; }
- (NSArray<NSString *> *)outputDeviceNames { return _outputDeviceNames; }
- (NSArray<NSNumber *> *)inputDeviceIndexes  { return _inputDeviceIndexes; }
- (NSArray<NSNumber *> *)outputDeviceIndexes { return _outputDeviceIndexes; }

- (void)setup {
    self.inputDeviceNames    = [NSMutableArray array];
    self.outputDeviceNames   = [NSMutableArray array];
    self.inputDeviceIndexes  = [NSMutableArray array];
    self.outputDeviceIndexes = [NSMutableArray array];
    _nodeEntries      = [[NSMutableDictionary alloc] init];
    _nodeNames        = [[NSMutableDictionary alloc] init];
    _metadataProxy    = NULL;
    _metadataNodeId   = SPA_ID_INVALID;
    _selectedInputId  = SPA_ID_INVALID;
    _selectedOutputId = SPA_ID_INVALID;

    pw_init(NULL, NULL);

    _threadLoop = pw_thread_loop_new("ambrosia-pipewire", NULL);
    if (!_threadLoop) {
        NSLog(@"PipeWire: failed to create thread loop");
        return;
    }

    _pwContext = pw_context_new(pw_thread_loop_get_loop(_threadLoop), NULL, 0);
    if (!_pwContext) {
        NSLog(@"PipeWire: failed to create context");
        return;
    }

    pw_thread_loop_lock(_threadLoop);

    if (pw_thread_loop_start(_threadLoop) < 0) {
        NSLog(@"PipeWire: failed to start thread loop");
        pw_thread_loop_unlock(_threadLoop);
        return;
    }

    _pwCore = pw_context_connect(_pwContext, NULL, 0);
    if (!_pwCore) {
        NSLog(@"PipeWire: failed to connect: %s", strerror(errno));
        pw_thread_loop_unlock(_threadLoop);
        return;
    }

    _pwRegistry = pw_core_get_registry(_pwCore, PW_VERSION_REGISTRY, 0);
    pw_registry_add_listener(_pwRegistry, &_registryListener,
                             &registry_events, (__bridge void *)self);

    pw_thread_loop_unlock(_threadLoop);
}

- (void)teardown {
    if (!_threadLoop) return;

    pw_thread_loop_lock(_threadLoop);

    spa_hook_remove(&_registryListener);

    for (NSValue *val in _nodeEntries.allValues) {
        PWNodeEntry *entry = (PWNodeEntry *)[val pointerValue];
        spa_hook_remove(&entry->node_listener);
        pw_proxy_destroy(entry->proxy);
        free(entry);
    }
    [_nodeEntries removeAllObjects];
    [_nodeEntries release];
    _nodeEntries = nil;

    [_nodeNames removeAllObjects];
    [_nodeNames release];
    _nodeNames = nil;

    if (_metadataProxy) {
        pw_proxy_destroy(_metadataProxy);
        _metadataProxy = NULL;
    }

    if (_pwRegistry) {
        pw_proxy_destroy((struct pw_proxy *)_pwRegistry);
        _pwRegistry = NULL;
    }
    if (_pwCore) {
        pw_core_disconnect(_pwCore);
        _pwCore = NULL;
    }

    pw_thread_loop_unlock(_threadLoop);
    pw_thread_loop_stop(_threadLoop);

    if (_pwContext) {
        pw_context_destroy(_pwContext);
        _pwContext = NULL;
    }
    pw_thread_loop_destroy(_threadLoop);
    _threadLoop = NULL;

    pw_deinit();
}

- (void)dealloc {
    [self teardown];
    [super dealloc];
}

#pragma mark - Volume / Mute

- (void)setInputVolume:(double)volume forDeviceIndex:(uint32_t)index {
    [self _setVolume:volume forDeviceIndex:index];
}

- (void)setOutputVolume:(double)volume forDeviceIndex:(uint32_t)index {
    [self _setVolume:volume forDeviceIndex:index];
}

- (void)_setVolume:(double)volume forDeviceIndex:(uint32_t)index {
    if (!_threadLoop) return;
    pw_thread_loop_lock(_threadLoop);
    NSValue *val = _nodeEntries[@(index)];
    if (val) {
        PWNodeEntry *entry = (PWNodeEntry *)[val pointerValue];
        uint8_t buf[512];
        struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buf, sizeof(buf));
        float vol = (float)(volume / 100.0);
        struct spa_pod *pod = (struct spa_pod *)spa_pod_builder_add_object(&b,
            SPA_TYPE_OBJECT_Props, SPA_PARAM_Props,
            SPA_PROP_volume, SPA_POD_Float(vol));
        pw_node_set_param((struct pw_node *)entry->proxy, SPA_PARAM_Props, 0, pod);
    }
    pw_thread_loop_unlock(_threadLoop);
}

- (void)setInputMute:(BOOL)mute forDeviceIndex:(uint32_t)index {
    [self _setMute:mute forDeviceIndex:index];
}

- (void)setOutputMute:(BOOL)mute forDeviceIndex:(uint32_t)index {
    [self _setMute:mute forDeviceIndex:index];
}

- (void)_setMute:(BOOL)mute forDeviceIndex:(uint32_t)index {
    if (!_threadLoop) return;
    pw_thread_loop_lock(_threadLoop);
    NSValue *val = _nodeEntries[@(index)];
    if (val) {
        PWNodeEntry *entry = (PWNodeEntry *)[val pointerValue];
        uint8_t buf[512];
        struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buf, sizeof(buf));
        struct spa_pod *pod = (struct spa_pod *)spa_pod_builder_add_object(&b,
            SPA_TYPE_OBJECT_Props, SPA_PARAM_Props,
            SPA_PROP_mute, SPA_POD_Bool(mute ? 1 : 0));
        pw_node_set_param((struct pw_node *)entry->proxy, SPA_PARAM_Props, 0, pod);
    }
    pw_thread_loop_unlock(_threadLoop);
}

- (void)setDefaultInputDevice:(uint32_t)index {
    if (!_threadLoop || !_metadataProxy) return;
    pw_thread_loop_lock(_threadLoop);
    NSString *name = _nodeNames[@(index)];
    if (name) {
        NSString *json = [NSString stringWithFormat:@"{\"name\":\"%@\"}", name];
        pw_metadata_set_property((struct pw_metadata *)_metadataProxy,
                                 PW_ID_ANY,
                                 "default.audio.source",
                                 "Spa:String:JSON",
                                 [json UTF8String]);
    }
    pw_thread_loop_unlock(_threadLoop);
}

- (void)setDefaultOutputDevice:(uint32_t)index {
    if (!_threadLoop || !_metadataProxy) return;
    pw_thread_loop_lock(_threadLoop);
    NSString *name = _nodeNames[@(index)];
    if (name) {
        NSString *json = [NSString stringWithFormat:@"{\"name\":\"%@\"}", name];
        pw_metadata_set_property((struct pw_metadata *)_metadataProxy,
                                 PW_ID_ANY,
                                 "default.audio.sink",
                                 "Spa:String:JSON",
                                 [json UTF8String]);
    }
    pw_thread_loop_unlock(_threadLoop);
}

- (void)refreshInputDevices {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate audioBackendDidUpdateInputDevices:self];
    });
}

- (void)refreshOutputDevices {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate audioBackendDidUpdateOutputDevices:self];
    });
}

- (void)refreshVolumeForInputDeviceIndex:(uint32_t)index {
    if (!_threadLoop) return;
    pw_thread_loop_lock(_threadLoop);
    _selectedInputId = index;
    NSValue *val = _nodeEntries[@(index)];
    if (val) {
        PWNodeEntry *entry = (PWNodeEntry *)[val pointerValue];
        uint32_t param_ids[] = { SPA_PARAM_Props };
        pw_node_subscribe_params((struct pw_node *)entry->proxy, param_ids, 1);
        pw_node_enum_params((struct pw_node *)entry->proxy, 0,
                            SPA_PARAM_Props, 0, 1, NULL);
    }
    pw_thread_loop_unlock(_threadLoop);
}

- (void)refreshVolumeForOutputDeviceIndex:(uint32_t)index {
    if (!_threadLoop) return;
    pw_thread_loop_lock(_threadLoop);
    _selectedOutputId = index;
    NSValue *val = _nodeEntries[@(index)];
    if (val) {
        PWNodeEntry *entry = (PWNodeEntry *)[val pointerValue];
        uint32_t param_ids[] = { SPA_PARAM_Props };
        pw_node_subscribe_params((struct pw_node *)entry->proxy, param_ids, 1);
        pw_node_enum_params((struct pw_node *)entry->proxy, 0,
                            SPA_PARAM_Props, 0, 1, NULL);
    }
    pw_thread_loop_unlock(_threadLoop);
}

#pragma mark - Internal helpers (called from PW callbacks, lock already held)

- (void)_registryGlobalId:(uint32_t)nodeId
                     type:(const char *)type
                  version:(uint32_t)version
                    props:(const struct spa_dict *)props {
    // Capture the "default" metadata object for setting default devices.
    if (strcmp(type, PW_TYPE_INTERFACE_Metadata) == 0) {
        const char *metaName = spa_dict_lookup(props, PW_KEY_METADATA_NAME);
        if (metaName && strcmp(metaName, "default") == 0 && !_metadataProxy) {
            _metadataProxy  = (struct pw_proxy *)pw_registry_bind(_pwRegistry,
                                  nodeId, PW_TYPE_INTERFACE_Metadata,
                                  PW_VERSION_METADATA, 0);
            _metadataNodeId = nodeId;
        }
        return;
    }

    if (strcmp(type, PW_TYPE_INTERFACE_Node) != 0) return;

    const char *media_class = spa_dict_lookup(props, PW_KEY_MEDIA_CLASS);
    if (!media_class) return;

    BOOL is_sink   = (strcmp(media_class, "Audio/Sink")   == 0);
    BOOL is_source = (strcmp(media_class, "Audio/Source") == 0);
    if (!is_sink && !is_source) return;

    const char *nodeName = spa_dict_lookup(props, PW_KEY_NODE_NAME);
    const char *desc     = spa_dict_lookup(props, PW_KEY_NODE_DESCRIPTION);
    if (!desc) desc       = spa_dict_lookup(props, PW_KEY_NODE_NICK);
    if (!desc) desc       = nodeName;
    if (!desc) desc       = "Unknown Device";

    struct pw_proxy *proxy = (struct pw_proxy *)pw_registry_bind(_pwRegistry,
                                                                 nodeId,
                                                                 PW_TYPE_INTERFACE_Node,
                                                                 PW_VERSION_NODE, 0);
    if (!proxy) return;

    PWNodeEntry *entry  = (PWNodeEntry *)calloc(1, sizeof(PWNodeEntry));
    entry->node_id      = nodeId;
    entry->proxy        = proxy;
    entry->is_sink      = is_sink;
    entry->backend_ref  = (__bridge void *)self;

    pw_node_add_listener((struct pw_node *)proxy, &entry->node_listener,
                         &node_events, entry);

    _nodeEntries[@(nodeId)] = [NSValue valueWithPointer:entry];
    if (nodeName)
        _nodeNames[@(nodeId)] = [NSString stringWithUTF8String:nodeName];

    NSString *description = [NSString stringWithUTF8String:desc];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (is_sink) {
            [self.outputDeviceNames addObject:description];
            [self.outputDeviceIndexes addObject:@(nodeId)];
            [self.delegate audioBackendDidUpdateOutputDevices:self];
        } else {
            [self.inputDeviceNames addObject:description];
            [self.inputDeviceIndexes addObject:@(nodeId)];
            [self.delegate audioBackendDidUpdateInputDevices:self];
        }
    });
}

- (void)_registryGlobalRemoveId:(uint32_t)nodeId {
    // Handle metadata removal.
    if (nodeId == _metadataNodeId && _metadataProxy) {
        pw_proxy_destroy(_metadataProxy);
        _metadataProxy  = NULL;
        _metadataNodeId = SPA_ID_INVALID;
        return;
    }
    NSValue *val = _nodeEntries[@(nodeId)];
    if (!val) return;
    PWNodeEntry *entry = (PWNodeEntry *)[val pointerValue];
    BOOL isSink = entry->is_sink;
    [_nodeEntries removeObjectForKey:@(nodeId)];
    [_nodeNames   removeObjectForKey:@(nodeId)];
    spa_hook_remove(&entry->node_listener);
    pw_proxy_destroy(entry->proxy);
    free(entry);
    NSNumber *idNum = @(nodeId);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (isSink) {
            NSUInteger i = [self.outputDeviceIndexes indexOfObject:idNum];
            if (i != NSNotFound) {
                [self.outputDeviceNames removeObjectAtIndex:i];
                [self.outputDeviceIndexes removeObjectAtIndex:i];
            }
            [self.delegate audioBackendDidUpdateOutputDevices:self];
        } else {
            NSUInteger i = [self.inputDeviceIndexes indexOfObject:idNum];
            if (i != NSNotFound) {
                [self.inputDeviceNames removeObjectAtIndex:i];
                [self.inputDeviceIndexes removeObjectAtIndex:i];
            }
            [self.delegate audioBackendDidUpdateInputDevices:self];
        }
    });
}

- (void)_handleParamNodeId:(uint32_t)nodeId isSink:(BOOL)isSink
                    volume:(float)volume mute:(int32_t)mute {
    if (isSink  && nodeId != _selectedOutputId) return;
    if (!isSink && nodeId != _selectedInputId)  return;
    double vol100 = (double)volume * 100.0;
    BOOL muteFlag = (mute != 0);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (isSink) {
            [self.delegate audioBackend:self didUpdateOutputVolume:vol100 mute:muteFlag];
        } else {
            [self.delegate audioBackend:self didUpdateInputVolume:vol100 mute:muteFlag];
        }
    });
}

@end

#pragma mark - C Callbacks

static void registry_global_cb(void *data, uint32_t id, uint32_t permissions,
                                const char *type, uint32_t version,
                                const struct spa_dict *props) {
    PipeWireBackend *backend = (__bridge PipeWireBackend *)data;
    [backend _registryGlobalId:id type:type version:version props:props];
}

static void registry_global_remove_cb(void *data, uint32_t id) {
    PipeWireBackend *backend = (__bridge PipeWireBackend *)data;
    [backend _registryGlobalRemoveId:id];
}

static void node_param_cb(void *data, int seq, uint32_t id,
                          uint32_t index, uint32_t next,
                          const struct spa_pod *param) {
    if (id != SPA_PARAM_Props || !param) return;
    PWNodeEntry *entry = (PWNodeEntry *)data;
    float   volume = 0.0f;
    int32_t mute   = 0;
    spa_pod_parse_object(param,
        SPA_TYPE_OBJECT_Props, NULL,
        SPA_PROP_volume, SPA_POD_OPT_Float(&volume),
        SPA_PROP_mute,   SPA_POD_OPT_Bool(&mute));
    PipeWireBackend *backend = (__bridge PipeWireBackend *)entry->backend_ref;
    [backend _handleParamNodeId:entry->node_id isSink:entry->is_sink
                         volume:volume mute:mute];
}
