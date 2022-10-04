# 1. Dealing with events and state

This client to the Hue system will connect and synchronise data with the Hue system.
This will be done in a 3 step process:

1. Connect to the Hue event stream
2. Load all resources available on the Hue bridge (to create an initial state)
3. Start processing the events from the event stream, to keep the state up to date

The client will also emit events based on changes in either Hue resources, or
the (connection) state of the client itself.

For the flow of events check the `"status"` events section below.

## 1.1 Hue resource state

The client will have 2 main keys for accessing Hue resources;

1. `"resources"` which is a table of all resources indexed by their UUID.
2. `"types"` which has subtables by resource type. Eg. `"light"`, `"scene"`, or `"grouped_light"`.
Each of those sub-tables is indexed by the UUID again, and contains only the resources of that specific type.

References in those trees to other resources will be dereferenced to the actual resources in the same tree.

```lua
local light_resource_uuid = "xyz"

assert(hue.resources[light_resource_uuid] == hue.types.light[light_resource_uuid])

-- direct access to referenced resources:
local owning_device = hue.types.light[light_resource_uuid].owner
print(owning_device.product_data.product_name)
```

## 1.2 Events

An event is a table containing data. The main field in any `event` is the `type` field.

- `"status"` events indicate a status update of the connection to the Hue bridge.

- `"hue"` type events indicate a change in a Philips Hue resource.

## 1.3 `"status"` events

The current operational status is reflected in the `hue.state` field. A state change will be
followed by a `"status"` type event.

The status events will happen according to the following flow;

1. `Hue.states.CLOSED`: Not started yet, the initial state (no event emitted).
1. `Hue.states.INITIALIZING`: start fetching and building the initial state. During this phase
a number of `"add"` events (type `"hue"`) will happen as the data comes in.
1. `Hue.states.CONNECTING`: initial state is complete now, connecting to the event stream.
1. `Hue.states.OPEN`: the event stream is open and events are being dealt with.
1. from here it can cycle to `Hue.states.CONNECTING` and `Hue.states.OPEN` again if there are connection failures (reconnecting is done automatically).
1. `Hue.states.CLOSED`: after the client code decides to stop the Hue client.

The event-object will look like this:
```lua
  event = {
    client = self,                   -- the hue client object
    type = "status",
    event = Hue.states.INITIALIZING, -- one of the Hue.states.XXX constants
  }
```


## 1.4 `"hue"` events

There are three events (in the `event` field of the event-object)

1. `"add"` a resource was added. The resource will be added to the state in the client before the event fires.
The event-object will look like this:
```lua
  event = {
    client = self,
    type = "hue",
    event = "add",
    current = dereferenced_resource_as_kept_in_state_tables,
    received = received_non_dereferenced_resource_data,
  }
```

2. `"update"` a resource was updated. The resource will be updated in the state in the client before the event fires.
The resources as kept in the client state will be updated in-place. So if you keep a reference
to a resource, the contents of that table will change as well. Tables will not change, only their contents (the
exception being: if a referencen to another resource changes).
If you want to keep track of the old-state, you'll have to make a copy of the values to track on each event.
The event will look like this:
```lua
  event = {
    client = self,
    type = "hue",
    event = "update",
    current = dereferenced_resource_as_kept_in_state_tables,
    received = changed_only_props_in_received_non_dereferenced_resource_data,
  }
```

3. `"delete"` a resource was deleted. The resource will be removed from the state in the client before the event fires.
The event will look like this:
```lua
  event = {
    client = self,
    type = "hue",
    event = "delete",
    current = dereferenced_resource_removed_from_state_tables,
    received = received_non_dereferenced_resource_data,
  }
```

