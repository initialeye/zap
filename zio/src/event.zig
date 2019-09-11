const std = @import("std");
const zio = @import("../zio.zig");

/// Represents an IO event generated by either
/// an IO object or the user explicitely.
pub const Event = struct {
    inner: zio.backend.Event,

    pub const OneShot = 1 << 0;
    pub const Readable = 1 << 1;
    pub const Writeable = 1 << 2;
    pub const EdgeTrigger = 1 << 3;

    /// Get whatever user data was attached to the IO object handle
    /// or that was requested when generating a user-based event.
    pub inline fn getData(self: *@This(), poller: *Poller) usize {
        return self.inner.getData(&poller.inner);
    }

    /// Get the result of the IO operation which triggered this event.
    /// This is used to decide how to finish and process the IO operation.
    ///     - `zio.Result.Status.Error`:
    ///         The operation resulted in an error.
    ///         One should `.close()` any handles related.
    ///     - `zio.Result.Status.Retry`:
    ///         There is data ready on the corresponding handle.
    ///         Retry the IO operation in order to get the "true" `zio.Result`
    ///         `zio.Result.data` may contain hints for retrying the operation.
    ///     - `zio.Result.Status.Partial`:
    ///         The operation completed, but only partially.
    ///         `zio.Result.data` contains the data transferred regardless.
    ///         Reperform the IO operation in order to consume the remaining data.
    ///     - `zio.Result.Status.Completed`:
    ///         The operation completed fully and successfully.
    ///     
    pub inline fn getResult(self: *@This()) zio.Result {
        return self.inner.getResult();
    }

    /// An IO object used for polling events from other non-blocking IO objects.
    pub const Poller = struct {
        inner: zio.backend.Event.Poller,

        pub const InitError = error {
            OutOfResources,
        };

        /// Initialize the event poller IO object.
        pub inline fn init(self: *@This()) InitError!void {
            return self.inner.init();
        }

        /// Close the event poller & unregister any IO Objects previously registered.
        pub inline fn close(self: *@This()) void {
            return self.inner.close();
        }

        /// Get the internal `Handle` for the event poller
        pub inline fn getHandle(self: @This()) zio.Handle {
            return self.inner.getHandle();
        }

        /// Create an event poller from a given `Handle`.
        /// This should not be called from a `Poller` handle which has previously invoked `send()`
        pub inline fn fromHandle(handle: zio.Handle) @This() {
            return @This() { .inner = zio.backend.Poller.fromHandle(handle) };
        }

        pub const RegisterError = error {
            InvalidValue,
            InvalidHandle,
            OutOfResources,
        };
        
        /// Register a kernel object handle to listen for IO event.
        /// `data` is arbitrary user data which can be retrieved from `Event.getData()`:
        ///     - `data` of `std.math.maxInt(usize)` or `~usize(0)` is reserved to distinguish user events.
        /// `flags` is a bitmask used to determine when and what type of events to trigger:
        ///     - `Readable`: trigger an event when the handle receives data in the READ pipe.
        ///     - `Writeable`: trigger an event when the handle receives data in the WRITE pipe.
        ///     - `EdgeTrigger`: once an event has been triggered, it will be retriggered after the IO is consumed.
        ///     - `OneShot`(default): once an event has been triggered, it will no longer trigger unless `reregister()`ed
        pub inline fn register(self: *@This(), handle: zio.Handle, flags: u8, data: usize) RegisterError!void {
            return self.inner.register(handle, flags, data);
        }

        /// Similar to `register()` but fo modifying an existing event registration.
        pub inline fn reregister(self: *@This(), handle: zio.Handle, flags: u8, data: usize) RegisterError!void {
            return self.inner.reregister(handle, flags, data);
        }

        pub const SendError = std.os.UnexpectedError || RegisterError || error {
            InvalidValue,
            OutOfResources,
        };

        /// Send a user event with arbitrary `data` that can be retrieved from `Event.getData()`
        pub inline fn send(self: *@This(), data: usize) SendError!void {
            return self.inner.send(data);
        }

        pub const PollError = error {
            InvalidHandle,
            InvalidEvents,
        };

        /// Poll for IO events using the event poller.
        /// Returns a portion of the `events` slice containing triggered IO events.
        /// `timeout` is the number of milliseconds to block for events until giving up:
        ///     - `timeout` value of `std.math.maxInt(u32)` or `~u32(0)` is reserved.
        ///     - if `timeout` is `null`, then it will block until an IO event gets triggered.
        pub inline fn poll(self: *@This(), events: []Event, timeout: ?u32) PollError![]Event {
            if (events.len == 0)
                return events[0..0];
            const events_found = try self.inner.poll(@ptrCast([*]zio.backend.Event, events.ptr)[0..events.len], timeout);
            return @ptrCast([*]Event, events_found.ptr)[0..events_found.len];
        }
    };
};

const expect = std.testing.expect;

test "Event.Poller - poll - nonblock" {
    var poller: Event.Poller = undefined;
    try poller.init();
    defer poller.close();

    var events: [1]Event = undefined;
    const events_found = try poller.poll(events[0..], 0);
    expect(events_found.len == 0);
}

test "Event.Poller - send" {
    var poller: Event.Poller = undefined;
    try poller.init();
    defer poller.close();

    const value = usize(1234);
    try poller.send(value);

    var events: [1]Event = undefined;
    const events_found = try poller.poll(events[0..], 0);
    expect(events_found.len == 1);
    expect(events_found[0].getData(&poller) == value);
}
