const std = @import("std");
const zap = @import("../zap.zig");

const core = zap.core;
const system = std.os.system;
const Condition = core.sync.Condition;
const Atomic = core.sync.atomic.Atomic;

pub const Futex = extern struct {
    event: OsEvent = undefined,

    pub fn wait(self: *Futex, deadline_ptr: ?*Timestamp, condition: *Condition) bool {
        const deadline = if (deadline_ptr) |ptr| ptr.* else null;
        return self.event.wait(deadline, condition);
    }

    pub fn wake(self: *Futex) void {
        self.event.set();
    }

    pub const Timestamp = u64;

    pub const nanotime = Clock.nanotime;

    pub fn timestamp(self: *Futex, current: *Timestamp) void {
        current.* = nanotime();
    }

    pub fn timeSince(self: *Futex, t1: *Timestamp, t2: *Timestamp) u64 {
        return t1.* - t2.*;
    }
};

const Clock = struct {
    var last_now: u64 = 0;
    var last_lock = core.sync.Lock{};

    fn nanotime() u64 {
        const now = OsEvent.nanotime();
        if (OsEvent.is_actually_monotonic)
            return now;

        if (std.meta.bitCount(usize) < 64) {
            last_lock.acquire(Futex);
            defer last_lock.release();

            const last = last_now;
            if (last > now)
                return last;

            last_now = now;
            return now;
        }

        var last = @atomicLoad(u64, &last_now, .Monotonic);
        while (true) {
            if (last > now)
                return last;
            last = @cmpxchgWeak(
                u64,
                &last_now,
                last,
                now,
                .Monotonic,
                .Monotonic,
            ) orelse return now;
        }
    }

    fn ReturnTypeOf(comptime function: anytype) type {
        return @typeInfo(@TypeOf(function)).Fn.return_type.?;
    }

    fn getCachedFrequency(comptime getFrequencyFn: anytype) ReturnTypeOf(getFrequencyFn) {
        const Frequency = ReturnTypeOf(getFrequencyFn);
        const FrequencyState = enum(usize) {
            uninit,
            storing,
            init,
        };

        const Cached = struct {
            var frequency: Frequency = undefined;
            var frequenc_state = Atomic(FrequencyState).init(.uninit);
            
            fn get() Frequency {
                if (frequenc_state.load(.acquire) == .init)
                    return frequency;
                return getSlow();
            }

            fn getSlow() Frequency {
                @setCold(true);

                const local_frequency = getFrequencyFn();

                if (frequenc_state.compareAndSwap(
                    .uninit,
                    .storing,
                    .relaxed,
                    .relaxed,
                ) == null) {
                    frequency = local_frequency;
                    frequenc_state.store(.init, .release);
                }

                return local_frequency;
            }
        };

        return Cached.get();
    }
};

const OsEvent =
    if (core.is_windows)
        WindowsEvent
    else if (core.link_libc and core.is_posix)
        PosixEvent
    else if (core.is_linux)
        LinuxEvent
    else
        @compileError("OS thread blocking/unblocking not supported");


const WindowsEvent = extern struct {
    thread_id: Atomic(system.DWORD) = undefined,

    fn wait(self: *OsEvent, deadline: ?u64, condition: *Condition) bool {
        self.thread_id.set(GetCurrentThreadId());

        if (condition.isMet())
            return true;

        var timed_out = false;
        var timeout: system.LARGE_INTEGER = undefined;
        var timeout_ptr: ?*system.LARGE_INTEGER = null;

        if (deadline) |deadline_ns| {
            const now = Clock.nanotime();
            timed_out = now > deadline_ns;
            if (!timed_out) {
                timeout_ptr = &timeout;
                timeout = @intCast(system.LARGE_INTEGER, deadline_ns - now);
                timeout = -(@divFloor(timeout, 100));
            }
        }

        if (!timed_out) {
            switch (NtWaitForAlertByThreadId(null, timeout_ptr)) {
                .TIMEOUT => {},
                .ALERTED => return true,
                else => @panic("NtWaitForAlertByThreadId() unhandled status code"),
            }
        }

        if (self.thread_id.swap(0, .acquire) == 0) {
            switch (NtWaitForAlertByThreadId(null, null)) {
                .ALERTED => {},
                else => @panic("NtWaitForAlertByThreadId() unhandled status code"),
            }
        }

        return false;
    }

    fn set(self: *OsEvent) void {
        const thread_id = self.thread_id.swap(0, .release);
        if (thread_id == 0)
            return;

        switch (NtAlertThreadByThreadId(@intToPtr(?system.HANDLE, thread_id))) {
            .SUCCESS => {},
            .INVALID_CID => @panic("NtAlertThreadByThreadId() invalid thread id"),
            else => @panic("NtAlertThreadByThreadId() unhandled status code"),
        }
    }

    const is_actually_monotonic = false;

    fn nanotime() u64 {
        const frequency = Clock.getCachedFrequency(system.QueryPerformanceFrequency);
        const counter = system.QueryPerformanceCounter();
        return @divFloor(counter *% std.time.ns_per_s, frequency);
    }

    extern "kernel32" fn GetCurrentThreadId() callconv(.Stdcall) system.DWORD;

    extern "NtDll" fn NtAlertThreadByThreadId(
        thread_id: ?system.HANDLE,
    ) callconv(.Stdcall) system.NTSTATUS;

    extern "NtDll" fn NtWaitForAlertByThreadId(
        address: ?system.PVOID,
        timeout: ?*const system.LARGE_INTEGER,
    ) callconv(.Stdcall) system.NTSTATUS;    
};

const LinuxEvent = extern struct {
    state: Atomic(State) = undefined,

    const State = extern enum(i32) {
        waiting,
        notified,
    };

    fn wait(self: *OsEvent, deadline: ?u64, condition: *Condition) bool {
        self.state.set(.waiting);

        if (condition.isMet())
            return true;

        var ts: system.timespec = undefined;
        var ts_ptr: ?*system.timespec = null;

        while (true) {
            switch (self.state.load(.acquire)) {
                .waiting => {},
                .notified => return true,
            }

            if (deadline) |deadline_ns| {
                const now = Clock.nanotime();
                if (now > deadline_ns)
                    return false;

                const duration = deadline_ns - now;
                ts_ptr = &ts;
                ts.tv_sec = @intCast(@TypeOf(ts.tv_sec), @divFloor(duration, std.time.ns_per_s));
                ts.tv_nsec = @intCast(@TypeOf(ts.tv_nsec), @mod(duration, std.time.ns_per_s));
            }

            const rc = system.futex_wait(
                @ptrCast(*const i32, &self.state),
                system.FUTEX_PRIVATE_FLAG | system.FUTEX_WAIT,
                @as(i32, @enumToInt(State.waiting)),
                ts_ptr,
            );

            switch (system.getErrno(rc)) {
                0 => continue,
                system.EINTR => continue,
                system.EAGAIN => return true,
                system.ETIMEDOUT => return false,
                else => @panic("futex(WAIT) unhandled errno code"),
            }
        }
    }

    fn set(self: *OsEvent) void {
        self.state.store(.notified, .release);

        const rc = system.futex_wake(
            @ptrCast(*const i32, &self.state),
            system.FUTEX_PRIVATE_FLAG | system.FUTEX_WAKE,
            @as(i32, 1),
        );

        switch (system.getErrno(rc)) {
            0 => {},
            system.EFAULT => {},
            else => @panic("futex(WAKE) unhandled errno"),
        }
    }

    const nanotime = PosixEvent.nanotime;

    const is_actually_monotonic = switch (core.os_type) {
        .linux => core.arch_type != .aarch64 and .arch_type != .s390x,
        .openbsd => core.arch_type != .x86_64,
        else => true,
    };
};

const PosixEvent = extern struct {
    event: Atomic(?*PthreadEvent) = Atomic(?*PthreadEvent).init(null),

    fn wait(self: *OsEvent, deadline: ?u64, condition: *Condition) bool {
        var has_stack_event = false;
        var stack_event: PthreadEvent = undefined;
        defer if (has_stack_event)
            stack_event.deinit();

        const event = PthreadEvent.get() orelse blk: {
            stack_event.init() catch unreachable;
            has_stack_event = true;
            break :blk &stack_event;
        };

        event.reset();
        self.event.set(event);
        if (condition.isMet())
            return true;

        event.wait(deadline);
        if (self.event.load(.acquire) == null)
            return true;

        if (self.event.swap(null, .acquire) == null)
            event.wait(null);
        return false;
    }

    fn set(self: *OsEvent) void {
        if (self.event.swap(null, .acq_rel)) |event|
            event.notify();
    }

    const is_actually_monotonic = 
        if (core.is_linux) LinuxEvent.is_actually_monotonic
        else true;

    fn nanotime() u64 {
        if (core.is_darwin) {
            const frequency = Clock.getCachedFrequency(struct {
                fn get() system.mach_timebase_info_data {
                    var info: @TypeOf(@This().get()) = undefined;
                    system.mach_timebase_info(&info);
                    return info;
                }
            }.get);
            const counter = system.mach_absolute_time();
            return @divFloor(counter *% frequency.numer, frequency.denom);
        }
        
        var ts: system.timespec = undefined;
        clock_gettime("CLOCK_MONOTONIC", &ts);
        return (@intCast(u64, ts.tv_sec) * std.time.ns_per_s) + @intCast(u64, ts.tv_nsec);
    }

    fn clock_gettime(comptime clock_id: []const u8, ts: *system.timespec) void {
        const rc = system.clock_gettime(@field(system, clock_id), ts);
        if (system.getErrno(rc) != 0)
            @panic("clock_gettime(" ++ clock_id ++ ") unhandled errno");
    }

    const PthreadEvent = struct {
        is_waiting: bool,
        is_notified: bool,
        cond: pthread_cond_t,
        mutex: pthread_mutex_t,

        fn init(self: *PthreadEvent) !void {
            var cond_attr: pthread_condattr_t = undefined;
            var cond_attr_ptr: ?*pthread_condattr_t = null;
            const use_clock_monotonic = !core.is_darwin and !core.is_android;

            if (use_clock_monotonic and pthread_condattr_init(&cond_attr) != 0)
                return error.PthreadCondAttrInit;
            defer if (use_clock_monotonic) {
                _ = pthread_condattr_destroy(&cond_attr);
            };

            if (use_clock_monotonic) {
                cond_attr_ptr = &cond_attr;
                if (pthread_condattr_setclock(&cond_attr, system.CLOCK_MONOTONIC) != 0)
                    return error.PthreadCondAttrSetClock;
            }

            if (pthread_cond_init(&self.cond, cond_attr_ptr) != 0)
                return error.PthreadCondInit;
            errdefer _ = pthread_cond_destroy(&self.cond);

            if (pthread_mutex_init(&self.mutex, null) != 0)
                return error.PthreadMutexInit;
            errdefer _ = pthread_mutex_destroy(&self.mutex);
        }

        fn deinit(self: *PthreadEvent) void {
            if (pthread_cond_destroy(&self.cond) != 0)
                @panic("pthread_cond_destroy() failed");
            if (pthread_mutex_destroy(&self.mutex) != 0)
                @panic("pthread_mutex_destroy() failed");
        }

        fn lock(self: *PthreadEvent) void {
            if (pthread_mutex_lock(&self.mutex) != 0)
                @panic("pthread_mutex_lock() failed");
        }

        fn unlock(self: *PthreadEvent) void {
            if (pthread_mutex_unlock(&self.mutex) != 0)
                @panic("pthread_mutex_unlock() failed");
        }

        fn reset(self: *PthreadEvent) void {
            self.is_waiting = true;
            self.is_notified = false;
        }

        fn wait(self: *PthreadEvent, deadline: ?u64) void {
            self.lock();
            defer self.unlock();

            while (!self.is_notified) {
                const deadline_ns = deadline orelse {
                    if (pthread_cond_wait(&self.cond, &self.mutex) != 0)
                        @panic("pthread_cond_wait() failed");
                    continue;
                };

                const now = Clock.nanotime();
                if (now > deadline_ns) {
                    self.is_waiting = false;
                    return;
                }

                var ts: system.timespec = undefined;
                if (core.is_darwin) {
                    var tv: system.timeval = undefined;
                    if (system.gettimeofday(&tv, null) != 0)
                        @panic("gettimeofday() failed");
                    ts.tv_sec = @intCast(@TypeOf(ts.tv_sec), tv.tv_sec);
                    ts.tv_nsec = @intCast(@TypeOf(ts.tv_nsec), tv.tv_usec) * std.time.ns_per_us;
                } else if (core.is_android) {
                    clock_gettime("CLOCK_REALTIME", &ts);
                } else {
                    clock_gettime("CLOCK_MONOTONIC", &ts);
                }

                const duration = deadline_ns - now;
                ts.tv_sec += @intCast(@TypeOf(ts.tv_sec), @divFloor(duration, std.time.ns_per_s));
                ts.tv_nsec += @intCast(@TypeOf(ts.tv_nsec), @mod(duration, std.time.ns_per_s));

                const rc = pthread_cond_timedwait(&self.cond, &self.mutex, &ts);
                switch (rc) {
                    0, system.ETIMEDOUT => {},
                    else => @panic("pthread_cond_timedwait() unhandled errno"),
                }
            }
        }

        fn notify(self: *PthreadEvent) void {
            self.lock();
            defer self.unlock();

            self.is_notified = true;
            if (self.is_waiting) {
                if (pthread_cond_signal(&self.cond) != 0)
                    @panic("pthread_cond_signal() failed");
            }
        }

        var event_key: pthread_key_t = undefined;
        var event_key_state = Atomic(EventKeyState).init(.uninit);

        const EventKeyState = enum(usize) {
            uninit,
            loading,
            init,
            invalid,
        };

        fn getEventKey() ?pthread_key_t {
            if (event_key_state.load(.acquire) == .init)
                return event_key;
            return getEventKeySlow();
        }

        fn getEventKeySlow() ?pthread_key_t {
            @setCold(true);

            var state = event_key_state.load(.acquire);
            while (true) {
                state = switch (state) {
                    .uninit => event_key_state.tryCompareAndSwap(
                        .uninit,
                        .loading,
                        .acquire,
                        .acquire,
                    ) orelse blk: {
                        state = .init;
                        if (pthread_key_create(&event_key, destructor) != 0)
                            state = .invalid;
                        event_key_state.store(state, .release);
                        break :blk state;
                    },
                    .loading => blk: {
                        _ = sched_yield();
                        break :blk event_key_state.load(.acquire);
                    },
                    .init => return event_key,
                    .invalid => return null,
                };
            }
        }

        fn constructor() ?*c_void {
            const ptr = malloc(@sizeOf(PthreadEvent)) orelse return null;
            const event = @ptrCast(*PthreadEvent, @alignCast(@alignOf(PthreadEvent), ptr));
            event.init() catch {
                free(ptr);
                return null;
            };
            return ptr;
        }

        fn destructor(ptr: *c_void) callconv(.C) void {
            const event = @ptrCast(*PthreadEvent, @alignCast(@alignOf(PthreadEvent), ptr));
            event.deinit();
            free(ptr);
        }

        fn get() ?*PthreadEvent {
            const key = getEventKey() orelse return null;

            const ptr = pthread_getspecific(key) orelse blk: {
                const ptr = constructor() orelse return null;
                if (pthread_setspecific(key, ptr) == 0)
                    break :blk ptr;
                destructor(ptr);
                return null;
            };

            const event = @ptrCast(*PthreadEvent, @alignCast(@alignOf(PthreadEvent), ptr));
            return event;
        }

        const pthread_cond_t = pthread_t;
        const pthread_condattr_t = pthread_t;

        const pthread_mutex_t = pthread_t;
        const pthread_mutexattr_t = pthread_t;

        const pthread_key_t = usize;
        const pthread_t = extern struct {
            _opaque: [128]u8 align(16),
        };

        extern "c" fn malloc(bytes: usize) callconv(.C) ?*c_void;
        extern "c" fn free(ptr: ?*c_void) callconv(.C) void;
        extern "c" fn sched_yield() callconv(.C) c_int;

        extern "c" fn pthread_mutex_init(m: *pthread_mutex_t, a: ?*pthread_mutexattr_t) callconv(.C) c_int;
        extern "c" fn pthread_mutex_lock(m: *pthread_mutex_t) callconv(.C) c_int;
        extern "c" fn pthread_mutex_unlock(m: *pthread_mutex_t) callconv(.C) c_int;
        extern "c" fn pthread_mutex_destroy(m: *pthread_mutex_t) callconv(.C) c_int;

        extern "c" fn pthread_condattr_init(a: *pthread_condattr_t) callconv(.C) c_int;
        extern "c" fn pthread_condattr_setclock(a: *pthread_condattr_t, clock_id: c_int) callconv(.C) c_int;
        extern "c" fn pthread_condattr_destroy(a: *pthread_condattr_t) callconv(.C) c_int;

        extern "c" fn pthread_cond_init(c: *pthread_cond_t, a: ?*pthread_condattr_t) callconv(.C) c_int;
        extern "c" fn pthread_cond_wait(noalias c: *pthread_cond_t, noalias m: *pthread_mutex_t) callconv(.C) c_int;
        extern "c" fn pthread_cond_timedwait(noalias c: *pthread_cond_t, noalias m: *pthread_mutex_t, noalias t: *const system.timespec) callconv(.C) c_int;
        extern "c" fn pthread_cond_signal(c: *pthread_cond_t) callconv(.C) c_int;
        extern "c" fn pthread_cond_destroy(c: *pthread_cond_t) callconv(.C) c_int;

        extern "c" fn pthread_key_create(k: *pthread_key_t, d: fn(*c_void) callconv(.C) void) callconv(.C) c_int;
        extern "c" fn pthread_getspecific(k: pthread_key_t) callconv(.C) ?*c_void;
        extern "c" fn pthread_setspecific(k: pthread_key_t, v: ?*c_void) callconv(.C) c_int;
    };
};