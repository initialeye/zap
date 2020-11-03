const std = @import("std");

pub const Runtime = struct {


};

/// A Task represents an eventual continuation that can be freely scheduled on a thread pool.
pub const Task = struct {
    next: ?*Task,
    frame: anyframe,

    /// Initialize a continuation task using the given async frame.
    pub fn init(frame: anyframe) Task {
        return Task{
            .next = undefined,
            .frame = frame,
        };
    }

    /// Execute the continuation represented by this Task
    ///
    /// TODO: support callbacks instead of being restricted to zig async frames
    pub fn run(self: *Task) void {
        resume self.frame;
    }

    /// Schedule the task for eventual execution via its run() function in the thread pool.
    pub fn schedule(self: *Task) void {
        return Batch.from(self).schedule();
    }

    /// Schedule the task to be executed once the current task yields.
    /// Useful as a SwitchTo mechanism to ensure LIFO scheduling for cache-aware scheduling algorithms.
    ///
    /// Notes:
    /// - The scheduled task may not begin execution until the current caller Task suspends.
    /// - If there are two succeesive calls to scheduleNext() without suspended, 
    //      the previously scheduled task will be scheduled to the end of the local run queue.
    pub fn scheduleNext(self: *Task) void {
        const thread = Thread.getCurrent();
        if (thread.ptr != 1)
            thread.schedule(Batch.from(@intToPtr(*Task, thread.ptr)));
        thread.ptr = @ptrToInt(self);
    }

    /// Yield execution of the current/callers Task to the thread pool, allowing another task to run.
    pub fn yield() void {
        var task = Task.init(@frame());
        suspend {
            const thread = Thread.getCurrent();
            const pool = @intToPtr(*Thread.Pool, thread.ptr);
            pool.schedule(Task.Batch.from(&task));
        }
    }

    /// An ordered set of Task's which can be scheduled together at once.
    pub const Batch = struct {
        head: ?*Task = null,
        tail: *Task = undefined,
        len: usize = 0,

        /// Create a batch of tasks containing only the provided task
        pub fn from(task: *Task) Batch {
            task.next = null;
            return Batch{
                .head = task,
                .tail = task,
                .len = 1,
            };
        }

        /// Alias for `pushBack()`
        pub fn push(self: *Batch, task: *Task) void {
            return self.pushBack(task);
        }

        /// Enqueue a single task to the head-end of this batch.
        pub fn pushFront(self: *Batch, task: *Task) void {
            return self.pushFrontMany(Batch.from(task));
        }

        /// Enqueue a single task to the tail-end of this batch.
        pub fn pushBack(self: *Batch, task: *Task) void {
            return self.pushBackMany(Batch.from(task));
        }

        /// Enqueue a batch of tasks at the head-end of this batch.
        pub fn pushFrontMany(self: *Batch, other: Batch) void {
            const other_head = other.head orelse return;
            if (self.head) |head| {
                other.tail.next = head;
                self.head = other_head;
                self.len += other.len;
            } else {
                self.* = other;
            }
        }

        /// Enqueue a batch of tasks at the tail-end of this batch
        pub fn pushBackMany(self: *Batch, other: Batch) void {
            const other_head = other.head orelse return;
            if (self.head) |head| {
                self.tail.next = other_head;
                self.tail = other.tail;
                self.len += other.len;
            } else {
                self.* = other;
            }
        }

        /// Alias for `popFront()`
        pub fn pop(self: *Batch) ?*Task {
            return self.popFront();
        }

        /// Dequeue and return the head task of the batch
        pub fn popFront(self: *Batch) ?*Task {
            const task = self.head orelse return null;
            self.head = task.next;
            self.len -= 1;
            return task;
        }

        /// Schedule the batch of tasks into the currently running thread pool.
        /// Panics if the caller is not running in a task thread pool.
        /// This operation takes ownership of the batch's tasks so it may not be used after.
        pub fn schedule(self: Batch) void {
            return Thread.getCurrent().schedule(self);
        }
    };

    /// Options used to configure the thread pool which executes async tasks.
    pub const RunOptions = struct {
        /// The maximum amount of threads to use in the thread pool
        /// where the scheduled tasks can execute.
        max_threads: usize = std.math.maxInt(usize),

        /// Allocator used to allocate internal scheduler data structures.
        allocator: *std.mem.Allocator = switch (std.builtin.link_libc) {
            true => std.heap.c_allocator,
            else => std.heap.page_allocator,
        },
    };

    /// Possible errors that could occur when running a task in the thread pool.
    pub const RunError = std.mem.Allocator.Error || error{
        AsyncFnDeadlocked,
    };

    /// Run an async function, and all tasks which it spawns recursively, in a thread pool.
    /// Returns the result of the async fn if it completed and an error if not.
    pub fn run(
        options: RunOptions,
        comptime async_fn: anytype,
        fn_args: anytype,
    ) RunError!@TypeOf(async_fn).ReturnType {
        // wrap the async_fn to run it on the thread pool
        const ArgsType = @TypeOf(fn_args);
        const ReturnType = @TypeOf(async_fn).ReturnType;
        const Wrapper = struct {
            fn call(args: ArgsType, task: *Task, result: *?ReturnType) void {
                suspend task.* = Task.init(@frame());
                const res = @call(.{}, async_fn, args);
                result.* = res;
            }
        };

        // prepare the task for the thread pool which will run the async fn
        var task: Task = undefined;
        var result: ?ReturnType = null;
        var frame = async Wrapper.call(fn_args, &task, &result);
        
        // decide the maximum amount of threads to use for the pool
        var max_threads = std.math.max(1, options.max_threads);
        if (std.builtin.single_threaded) {
            max_threads = 1;
        } else if (std.Thread.cpuCount()) |system_threads| {
            max_threads = std.math.min(system_threads, max_threads);
        } else |_| {}
        max_threads = std.math.min(Thread.Pool.MAX_SLOTS, max_threads);

        // try to allocate the slots on the stack, if possible, to run the thread pool
        const on_stack_slots = std.mem.page_size / 2 / @sizeOf(Thread.Pool.Slot);
        if (max_threads < on_stack_slots) {
            var slots: [on_stack_slots]Thread.Pool.Slot = undefined;
            Thread.Pool.runUsing(slots[0..], &task);
        
        // if not, allocate the slots in the provided allocator to run the thread pool
        } else {
            const allocator = options.allocator;
            const slots = try allocator.alloc(Thread.Pool.Slot, max_threads);
            defer allocator.free(slots);
            Thread.Pool.runUsing(slots, &task);
        }

        // try to return the result of the async fn after the thread pool completes all work.
        // if the result wasn't set, then the async fn ever ran to completion (i.e. deadlock).
        return result orelse RunError.AsyncFnDeadlocked;
    }
};

const Thread = struct {
    const Pool = struct {
        /// The maximum amount of Slots a Pool can contain.
        const MAX_SLOTS = std.math.maxInt(Index) - 1;

        /// Unsigned int type used to index into the Slot slice of a Pool
        const Index = @Type(std.builtin.TypeInfo{
            .Int = std.builtin.TypeInfo.Int{
                .is_signed = false,
                .bits = switch (std.builtin.arch) {
                    32 => 16,
                    64 => 32,
                    else => @compileError("Architecture not supported"),
                },
            },
        });

        /// A Slot represents a pointer to data used by a thread to store its pseudo execution state.
        /// A Slot array for each Thread is needed upfront in order to allow lock-free Thread suspend/resume.
        /// Slots are minimized into a single tagged pointer in order to convey as much info as possible with little memory.
        const Slot = struct {
            ptr: usize align(2),

            /// The pointer type which is represented in the Slot.ptr field.
            const Ptr = union(enum) {
                slot: ?*Slot,
                thread: *Thread,
                handle: ?*std.Thread,
                spawning: ?*std.Thread,

                /// Convert a Slot.Ptr into a tagged opaque pointer
                fn encode(self: Ptr) usize {
                    return switch (self) {
                        .slot => |ptr| @ptrToInt(ptr) | 0,
                        .thread => |ptr| @ptrToInt(ptr) | 1,
                        .handle => |ptr| @ptrToInt(ptr) | 2,
                        .spawning => |ptr| @ptrToInt(ptr) | 3,
                    };
                }

                /// Convert a tagged opaque pointer into a Slot.Ptr
                fn decode(value: usize) Ptr {
                    const ptr = value & ~@as(usize, 0b11);
                    return switch (value & 0b11) {
                        0 => Ptr{ .slot = @intToPtr(?*Slot, ptr) },
                        1 => Ptr{ .thread = @intToPtr(*Thread, ptr) },
                        2 => Ptr{ .handle = @intToPtr(?*std.Thread, ptr) },
                        3 => Ptr{ .spawning = @intToPtr(?*std.Thread, ptr) },
                    };
                }
            };
        };

        slots: []Slot,
        runq_stub: ?*Task,
        runq_tail: usize,
        runq_head: *Task,
        idle_queue: usize,
        active_threads: usize,

        const IS_POLLING = 1 << 0;
        const IS_WAKING = 1 << 1;
        const IS_NOTIFIED = 1 << 2;
        const IS_SHUTDOWN = 1 << 3;

        fn runUsing(slots: []Slot, task: *Task) void {
            if (slots.len == 0)
                return;

            // Initialze the thread pool on the stack of the first thread.

            var self = Pool{
                .slots = slots,
                .runq_stub = null,
                .runq_tail = undefined,
                .runq_head = undefined,
                .idle_queue = 0,
                .active_threads = 0,
            };

            const runq_stub = @fieldParentPtr(Task, "next", &self.runq_stub);
            self.runq_tail = @ptrToInt(runq_stub);
            self.runq_head = runq_stub;
            
            for (slots) |*slot, slot_index| {
                const next_slot_index = @intCast(Index, self.idle_queue >> 16);
                const next_slot = self.indexToSlot(next_slot_index);
                slot.ptr = (Slot.Ptr{ .slot = next_slot }).encode();
                self.idle_queue = @as(usize, @intCast(Index, slot_index + 1)) << 16;
            }

            // Run the threaed pool using this current thread and the current task.
            // Then wait for all threads to finish while deallocating their resources.

            self.push(Task.Batch.from(task));
            self.resumeThread(.{ .no_spawn = true });

            for (slots) |*slot| {
                const slot_ptr = @atomicLoad(usize, &slot.ptr, .Acquire);
                switch (Slot.Ptr.decode(slot_ptr)) {
                    .handle => |handle| {
                        const thread_handle = handle orelse continue;
                        thread_handle.wait();
                        const new_ptr = (Slot.Ptr{ .handle = null }).encode();
                        @atomicStore(usize, &slot.ptr, new_ptr, .Monotonic);
                    },
                    else => |invalid_slot_ptr| {
                        std.debug.panic("Pool.deinit() with invalid slot ptr {}", .{invalid_slot_ptr});
                    },
                }
            }

            // Safety checks to make sure the thread pool deinitalized

            const runq_tail = @atomicLoad(usize, &self.runq_tail, .Monotonic);
            const runq_head = @atomicLoad(*Task, &self.runq_head, .Monotonic);
            const idle_queue = @atomicLoad(usize, &self.idle_queue, .Monotonic);
            const active_threads = @atomicLoad(usize, &self.active_threads, .Monotonic);

            if (active_threads != 0)
                std.debug.panic("Pool.deinit() with {} active threads", .{active_threads});
            if (idle_queue & IS_SHUTDOWN == 0)
                std.debug.panic("Pool.deinit() when not shutdown", .{});
            if (runq_tail & IS_POLLING != 0)
                std.debug.panic("Pool.deinit() when runq is still polling", .{});
            if (runq_head != runq_stub)
                std.debug.panic("Pool.deinit() when runq is not empty", .{});
        }
        
        // Convert a non-zero slot index to a Thread slot pointer on the current thread pool. 
        fn indexToSlot(self: *Pool, index: Index) ?*Slot {
            if (index == 0)
                return null;
            return &self.slots[index - 1];
        }

        // Convert a slot pointer from the current pool into a non-zero Thread slot index
        fn slotToIndex(self: *Pool, slot: ?*Slot) Index {
            const slot_ptr = @ptrToInt(slot orelse return 0);
            const base_ptr = @ptrToInt(self.slots.ptr);
            const base_end = base_ptr + (self.slots.len * @sizeOf(Slot));

            if ((slot_ptr < base_ptr) or (slot_ptr >= base_end))
                std.debug.panic("Pool.slotToIndex() given invalid slot pointer {*}", .{slot_ptr});

            const index = (slot_ptr - base_ptr) / @sizeOf(Slot);
            return @intCast(Index, index - 1);
        }

        /// Options used to control how a thread is woken up when using a *resumeThread() function
        const ResumeOptions = struct {
            /// If true, don't spawn a new thread but instead reusing the caller thread
            no_spawn: bool = false,
            /// If true, then the caller was a thread previously waken by resumeThread() and found work.
            was_waking: bool = false,
        };

        /// Wake up a thread on the thread pool in order to run tasks using the provided options
        fn resumeThread(self: *Pool, options: ResumeOptions) void {
            _ = self.tryResumeThread(options);
        }

        /// The type of resume operation to perform and necessary pointer to do so.
        const ResumePtr = union(enum) {
            /// Spawn a Thread and associate it with the provided thread Slot.
            spawned: *Slot,
            /// Wake up the OS thread of an existing associated Thread.
            resumed: *Thread,
        };

        /// Try to wake up a thread on the thread pool in order to run tasks.
        /// Returns true if it was able to successfully do the equivalent of a thread spawn/resume.
        fn tryResumeThread(self: *Pool, options: ResumeOptions) bool {
            // Acquire ordering to ensure updated value to the slot from the index computed by the idle_queue
            var idle_queue = @atomicLoad(usize, &self.idle_queue, .Acquire);
            while (true) {
                if (idle_queue & IS_SHUTDOWN != 0)
                    std.debug.panic("Pool.resumeThread() when shutdown", .{});
                
                // if the caller didnt set the IS_WAKING bit 
                // and the queue is empty or theres already a thread being woken up,
                //      then theres nothing really left to try.
                if (!options.was_waking and (idle_queue & (IS_NOTIFIED | IS_WAKING) != 0))
                    return false;
                
                // prepare a new idle queue value to update with.
                // leave the aba counter unchanged as its only modified when pushing to the idle queue.
                const aba_mask = @as(usize, ~@as(u8, 0)) << 8;
                var new_idle_queue = idle_queue & aba_mask;

                // check if theres a pending slot on the idle quuee
                var new_resume_ptr: ?ResumePtr = null;
                if (self.indexToSlot(@truncate(Index, idle_queue >> 16))) |slot| {
                    var slot_index: Index = undefined;
                    switch (Slot.Ptr.decode(@atomicLoad(usize, &slot.ptr, .Acquire))) {
                        // theres a pending slot which isnt associated with a Thread yet, try to spawn it
                        .slot => |next_slot| {
                            slot_index = self.slotToIndex(next_slot);
                            new_resume_ptr = ResumePtr{ .spawned = slot };
                        },
                        // there is a pending slot which has an associated Thread, try to resume the Thread.
                        .thread => |thread| {
                            slot_index = self.slotToIndex(@atomicLoad(usize, &thread.ptr, .Unordered));
                            new_resume_ptr = ResumePtr{ .resumed = thread };
                        },
                        // some other thread is in the process of resuming this slot, so check back again
                        .spawning => {
                            idle_queue = @atomicLoad(usize, &self.idle_queue, .Acquire);
                            continue;
                        },
                        // this slot was marked as shutdown for some reason (should'nt happen).
                        .handle => {
                            std.debug.panic("Pool.resumeThread() found already shutdown thread", .{});
                        },
                    }
                    new_idle_queue |= (@as(usize, slot_index) << 16) | IS_WAKING;
                
                // the idle queue is empty, but there was no notification.
                // leave a notification that a resume() happened on the idle queue
                // so that lock-free suspending threads dont miss a wake-up request.
                } else {
                    new_idle_queue |= IS_NOTIFIED;
                }

                // Try to either notify a resume happened, or dequeue a pending slot on the idle queue.
                // Acquire barriers as read needs to be updated on slot computed by index in idle_queue.
                if (@cmpxchgWeak(
                    usize,
                    &self.idle_queue,
                    idle_queue,
                    new_idle_queue,
                    .Acquire,
                    .Acquire,
                )) |updated_idle_queue| {
                    idle_queue = updated_idle_queue;
                    continue;
                }

                // return true without bumping the active thread count below if it was just a notification
                const resume_ptr = new_resume_ptr orelse return true;
                const is_single_threaded = std.builtin.single_threaded or self.slots.len == 1;

                // increment the active_thread tracker as a new OS thread is about to be scheduled.
                _ = @atomicRmw(usize, &self.active_threads, .Add, 1, .Monotonic) + 1;

                switch (resume_ptr) {
                    .resumed => |thread| {
                        // single threaded pools shouldnt have any other threads to wake up
                        if (is_single_threaded)
                            std.debug.panic("Thread.resumeThread() waking a thread when single-threaded", .{});
                        
                        // wake up the thread & make sure its .ptr is the pool instead of null to avoid it shutting down
                        @atomicStore(usize, &thread.ptr, @ptrToInt(self), .Unordered);
                        thread.event.set();
                        return true;
                    },
                    .spawned => |slot| {
                        // prepare the slot ptr to be spawned.
                        @atomicStore(usize, &slot.ptr, (Slot.Ptr{ .spawning = null }).encode(), .Monotonic);
                        const run_info = RunInfo{
                            .pool = self,
                            .slot = slot,
                        };
                        
                        // use the current thread instead of spawning a new one if requested
                        if (options.no_spawn) {
                            Thread.run(run_info);
                            return true;
                        }

                        // single-threaded pools should never have to spawn a new thread, just use their own thread above.
                        if (is_single_threaded)
                            std.debug.panic("Thread.resumeThread() spawning a thread when single-threaded", .{});

                        if (std.Thread.spawn(run_info, Thread.run)) |handle| {
                            // spawned the thread and received a thread handle
                            // try to store the thread handle for the thread to see and consume.
                            const new_slot_ptr = @cmpxchgStrong(
                                usize,
                                &slot.ptr,
                                (Slot.Ptr{ .spawning = null }).encode(),
                                (Slot.Ptr{ .spawning = handle }).encode(),
                                .Release,
                                .Acquire,
                            ) orelse return true;

                            // If we lost the race to the thread, set its handle directly on the thread object instead.
                            switch (Slot.Ptr.decode(new_slot_ptr)) {
                                .thread => {
                                    thread.handle = handle;
                                    return true;
                                },
                                .slot => {
                                    std.debug.panic("Thread.resumeThread() spawned a thread that never spawned?", .{});
                                },
                                .handle => {
                                    std.debug.panic("Thread.resumeThread() spawned a thread that already shutdown?", .{});
                                },
                                .spawning => |handle| {
                                    std.debug.panic("Thread.resumeThread() spawning saw unknown handle {*}", .{handle});
                                },
                            }
                        } else |err| {}

                        // Failed to spawn a thread using the given slot, untrack it.
                        _ = @atomicRmw(usize, &self.active_threads, .Sub, 1, .Monotonic);

                        // Then add the slot we dequeued back into the idle_queue without a thread association
                        idle_queue = @atomicLoad(usize, &self.idle_queue, .Monotonic);
                        while (true) {
                            // set the slot's "next" link to form the LIFO idle_queue node
                            const next_slot_index = @truncate(Index, idle_queue >> 16);
                            const next_slot_ptr = Slot.Ptr{ .slot = self.indexToSlot(next_slot_index) };
                            @atomicStore(usize, &slot.ptr, next_slot_ptr.encode(), .Unordered);

                            // update the idle_queue slot index to our own, bump the ABA tag, and remove any waking or notification flags
                            const slot_index = self.slotToIndex(slot);
                            const aba_tag = @truncate(u8, idle_queue >> 8) +% 1;
                            const new_idle_queue = (@as(usize, slot_index) << 16) | (@as(usize, aba_tag) << 8);

                            // try to enqueue the slot back to effectively perform a rewind.
                            // Release barrier to ensure that other resumeThread() see valid slot.ptr unordered write above.
                            idle_queue = @cmpxchgWeak(
                                usize,
                                &self.idle_queue,
                                idle_queue,
                                new_idle_queue,
                                .Release,
                                .Monotonic,
                            ) orelse return false;
                        }
                    }
                }
            }
        }

        /// Push a batch of tasks to the pool's run queue in a *wait-free manner.
        /// 
        /// * The algorithm isnt technically wait-free 
        ///   as the queue is detached between the Xchg & the store.
        ///
        /// http://www.1024cores.net/home/lock-free-algorithms/queues/intrusive-mpsc-node-based-queue
        fn push(self: *Pool, batch: Task.Batch) void {
            const head = batch.head orelse return;
            const tail = batch.tail;
            const prev = @atomicRmw(*Task, &self.runq_head, .Xchg, tail, .AcqRel);
            @atomicStore(?*Task, &prev.next, head, .Release);
        }

        /// Pop a task from the pool's run queue in a *wait-free manner.
        ///
        /// * The algorithm isn't technically wait-free
        ///   since if a push() detaches the queue as above, this method returns null.
        ///
        /// http://www.1024cores.net/home/lock-free-algorithms/queues/intrusive-mpsc-node-based-queue
        fn pop(self: *Pool, runq_tail: **Task) ?*Task {
            var tail = runq_tail.*;
            var next = @atomicLoad(?*Task, &tail.next, .Acquire);

            const stub = @fieldParentPtr(Task, "next", &self.runq_stub);
            if (tail == stub) {
                tail = next orelse return null;
                runq_tail.* = tail;
                next = @atomicLoad(?*Runnable, &tail.next, .Acquire); 
            }

            if (next) |next_tail| {
                runq_tail.* = next_tail;
                return tail;
            }

            const head = @atomicLoad(*Task, &self.head, .Acquire);
            if (head != tail)
                return null;

            self.push(Task.Batch.from(stub));

            next = @atomicLoad(?*Task, &tail.next, .Acquire);
            runq_tail.* = next orelse return null;
            return tail;
        }

        /// Schedule a batch of tasks onto the thread pool from a caller outside of the thread pool.
        ///
        /// This defaults to pushing the batch of tasks to the back of the global
        /// run queue allowing previously scheduled tasks a turn on the Threads.
        pub fn schedule(self: *Pool, tasks: Task.Batch) void {
            self.push(tasks);
            self.resumeThread(.{});
        }
    };

    threadlocal var current: ?*Thread = null;

    /// Get a reference to the currently running Pool thread.
    /// Panics if the caller is not running in a thread Pool.
    fn getCurrent() *Thread {
        return Thread.current orelse {
            std.debug.panic("Tried to use a zap function outside it's scheduler", .{});
        };
    }

    ptr: usize,
    pool: *Pool,
    handle: ?*std.Thread,
    event: std.ResetEvent,
    runq_head: usize,
    runq_tail: usize,
    runq_buffer: [256]*Task,

    /// Information needed for a Thread to start running
    const RunInfo = struct {
        pool: *Pool,
        slot: *Slot,
    };

    /// Start running a Thread in the provided thread Pool using the caller's OS thread
    fn run(run_info: RunInfo) void {
        var is_waking = true;
        const pool = run_info.pool;
        const slot = run_info.slot;
        var prng = @truncate(Index, @ptrToInt(pool) ^ @ptrToInt(self));

        // allocate our Thread object on our OS thread's stack.
        var self = Thread{
            .ptr = undefined,
            .pool = pool,
            .handle = null,
            .event = std.ResetEvent.init(),
            .runq_head = 0,
            .runq_tail = 0,
            .runq_buffer = undefined,
        };

        // Associate the thread Slot with our Thread, saving the thread handle if provided.
        // AcqRel barrier used to ensure two properties:
        //  - Acquire barrier ensures up-to-date writes to the thread handle later on
        //  - Release barrier ensures the self: Thread init writes above are visible to other threads. 
        var slot_ptr = Slot.Ptr{ .thread = &self };
        slot_ptr = Slot.Ptr.decode(@atomicRmw(usize, &slot.ptr, .Xchg, slot_ptr.encode(), .AcqRel));
        switch (slot_ptr) {
            .spawning => |handle_ptr| {
                if (handle_ptr) |handle| {
                    self.handle = handle;
                }
            },
            else => {
                std.debug.panic("Thread.init() found invalid slot_ptr of {*}", .{slot_ptr});
            },
        }
        
        // continuously poll for tasks until the thread is shutdown
        while (true) {
            var polled_global = false;
            if (self.poll(pool, &prng, &polled_global)) |new_task| {
                
                // if a task was found and this thread was waking or found it in pool runq, wake another thread.
                // - the last waking thread wakes another instead of thundering herd waking to avoid contention.
                // - polling the pool runq acts as a lock so wake another thread that was waiting on said lock.
                if (is_waking or polled_global)
                    pool.resumeThread(.{ .was_waking = is_waking });
                is_waking = false;

                // A task was found, keep executing tasks if they keep yielding more
                var next_task: ?*Task = new_task;
                var direct_yields = 7;
                while (direct_yields) : (direct_yields -= 1) {
                    
                    // run the next task by starting with self.ptr to be the thread's pool pointer.
                    const task = next_task orelse break;
                    @atomicStore(usize, &self.ptr, 1, .Unordered);
                    task.run();

                    // if the task above yielded a new task, it would be inside self.ptr, replacing the pool above.
                    next_task = null;
                    if (self.ptr != 1) {
                        next_task = @intToPtr(*Task, self.ptr);
                    }
                }

                // re-poll for more tasks after executing the last.
                // if a "yielded into" task was not processed, reschedule it to let other tasks run 
                if (next_task) |task| {
                    self.schedule(Task.Batch.from(task));
                }
                continue;
            }

            // this thread found no work/tasks in the thread pool so it should sleep until woken up.
            const suspended = pool.suspendThread(&self);
            if (suspended) {
                self.event.wait();
            }
            
            // the thread was woken up after a suspend, check if it was shutdown or not
            if (self.ptr == 0) {
                break;
            } else if (suspended) {
                self.event.reset();
            }
        }

        // de-initialize the Thread with some safety checks
        self.event.deinit();
        const runq_tail = self.runq_tail;
        const runq_head = @atomicLoad(usize, &self.runq_head, .Monotonic);
        if (runq_tail != runq_head)
            std.debug.panic("Thread.deinit() with invalid runq size of {}", .{runq_tail -% runq_head});
    }

    /// Check for a task that the current thread can execute.
    fn poll(
        self: *Thread,
        pool: *Pool,
        prng: *Index,
        polled_global: *bool,
    ) ?*Task {
        // first check for tasks locally
        if (self.pollLocal()) |task| {
            return task;
        }

        // then check for tasks globally (which fills in local pools)
        if (self.pollGlobal(pool)) |task| {
            polled_global.* = true;
            return task;
        }
        
        // generate a random number (using xorshift)
        var rng = prng.*;
        switch (Index) {
            u16 => {
                rng ^= rng << 7;
                rng ^= rng >> 9;
                rng ^= rng << 8;
            },
            u32 => {
                rng ^= rng << 13;
                rng ^= rng >> 17;
                rng ^= rng << 5;
            },
            else => unreachable,
        }
        prng.* = rng;

        // use the random number to iterate the pool's slots 
        // starting at a random position in order to avoid steal contention.
        const num_slots = pool.slots.len;
        var slot_iter = num_slots;
        var slot_index = rng % num_slots;

        while (slot_iter != 0) : (slot_iter -= 1) {
            const slot = &pool.slots[slot_index];
            if (slot_index == num_slots - 1) {
                slot_index = 0;
            } else {
                slot_index += 1;
            }

            const slot_ptr = @atomicLoad(usize, &slot.ptr, .Acquire);
            switch (Slot.Ptr.decode(slot_ptr)) {
                .slot => {},
                .spawning => {},
                .handle => {
                    std.debug.panic("Thread.poll() found thread which was shutdown", .{});
                },
                .thread => |thread| {
                    if (thread == self)
                        continue;
                    if (self.pollSteal(thread)) |task|
                        return task;
                },
            }
        }

        // no tasks (that this thread could run) were found in the thread pool...
        return null;
    }

    /// Check for a task by polling the local run queue of this Thread
    fn pollLocal(self: *Thread) ?*Task {
        const tail = self.runq_tail;
        var head = @atomicLoad(usize, &self.runq_head, .Monotonic);
        while (head != tail) {
            
            const size = tail -% head;
            if (size > self.runq_buffer.len)
                std.debug.panic("Thread.pollLocal() with invalid runq size of {}", .{size});

            head = @cmpxchgWeak(
                ?*Task,
                &self.runq_head,
                head,
                head +% 1,
                .Monotonic,
                .Monotonic,
            ) orelse return self.runq_buffer[head % self.runq_buffer.len];
        }

        return null;
    }

    /// Check for a task by trying to steal from the run queue of another Thread
    fn pollSteal(self: *Thread, target: *Thread) ?*Task {
        const tail = self.runq_tail;
        const head = @atomicLoad(usize, &self.runq_head, .Monotonic);
        if (tail != head)
            std.debug.panic("Thread.pollSteal() when not empty with runq size of {}", .{tail -% head});
        
        // Load target_tail with Acquire barrier to ensure reading valid Task pointers when stealing.
        var target_head = @atomicLoad(usize, &target.runq_head, .Monotonic);
        while (true) {
            const target_tail = @atomicLoad(usize, &target.runq_tail, .Acquire);

            // handle the case when the target_tail was updated a lot since the last target_head load.
            const target_size = target_tail -% target_head;
            if (target_size > target.runq_buffer.len) {
                target_head = @atomicLoad(usize, &target.runq_head, .Monotonic);
                continue;
            }

            // prepare to steal half of the target runq's tasks into our own local runq.
            var steal = target_size - (target_size / 2);
            if (steal == 0) {
                return null;
            }
            
            // Will be returning the first stolen task from the target runq.
            // .Unordered loads are required when reading from remote runq's to avoid LLVM UB.
            steal -= 1;
            var new_tail = tail;
            var new_target_head = target_head +% 1;
            var task_ptr = &target.runq_buffer[target_head % target.runq_buffer.len];
            const first_task = @atomicLoad(*Task, task_ptr, .Unordered);
            
            // Copy the tasks from the target's runq into our runq
            // .Unordered loads are required when reading from remote runq's to avoid LLVM UB.
            // .Unordered stores are required when writing to our runq to avoid LLVM UB on stealer Threads.
            while (steal != 0) : (steal -= 1) {
                task_ptr = &target.runq_buffer[new_target_head % target.runq_buffer.len];
                const task = @atomicLoad(*Task, task_ptr, .Unordered);

                task_ptr = &self.runq_buffer[new_tail % self.runq_buffer.len];
                @atomicStore(*Task, task_ptr, task, .Unordered);

                new_target_head +%= 1;
                new_tail +%= 1;
            }

            // Try to commit the target runq steal by bumping the head position.
            // AcqRel barrier on success is used to ensure two properties:
            // - an Acquire barrier to ensure the tail store below isnt done before the steal actually commits
            // - a Release barrier to ensure that the loads from the target runq arent reordered after the steal commits.
            if (@cmpxchgWeak(
                usize,
                &target.runq_head,
                target_head,
                new_target_head,
                .AcqRel,
                .Monotonic,
            )) |updated_target_head| {
                target_head = updated_target_head;
                continue;
            }

            // Update our runq tail to make the tasks we stole available to be stolen from other Threads.
            // Release barrier to ensure that our local runq writes during the copy are visible to the stealer Threads.
            if (new_tail != tail)
                @atomicStore(usize, &self.runq_tail, new_tail, .Release);
            return first_task;
        }
    }

    /// Check for a task by polling the shared run queue in the Thread Pool
    fn pollGlobal(self: *Thread, pool: *Pool) ?*Task {
        // try to acquire the ability to poll() from the thread pool's run queue
        var runq_tail = blk: {
            var runq_tail = @atomicLoad(usize, &pool.runq_tail, .Monotonic);
            while (runq_tail & IS_POLLING == 0) {
                runq_tail = @cmpxchgWeak(
                    usize,
                    &pool.runq_tail,
                    runq_tail,
                    runq_tail | IS_POLLING,
                    .Acquire,
                    .Monotonic,
                ) orelse break :blk @intToPtr(*Task, runq_tail);
            }
            return false;
        };
        
        // pop one task from the pool's run queue as the first task to return
        var first_task = pool.pop(&runq_tail);

        // try to pop many tasks from the pool runq and store it in out local runq
        var tail = self.runq_tail;
        var new_tail = tail;
        var head = @atomicLoad(usize, &self.runq_head, .Monotonic);

        while (true) {
            var size = new_tail -% head;
            if (size > self.runq_buffer.len)
                std.debug.panic("Thread.pollGlobal() with invalid local runq size of {}", .{size});

            // try to pop a task from the pool's run queue if there is room in our local run queue.
            var new_task: ?*Task = null;
            if (size != self.runq_buffer.len)
                new_task = pool.pop(&runq_tail);

            // prepare the new task to be added to our local run queue if there was one.
            // if not, commit the local runq buffer writes we've done so far by updating the tail.
            // after updating the tail, recheck the head to see if tasks were stolen so we can add more.
            //
            // SeqCst barrier on the tail update to ensure two properties:
            // - a Release barrier on the tail for Threads stealing from our runq see updated Task writes
            // - a Full barrier to prevent the head load from being reordered before the tail store.
            //      Release/Acquire barriers on the store/loads respectively is not enough as
            //          Release prevents *other* loads/stores from being reordered after it and
            //          Acquire prevents *other* loads/stores from being reordered before it.
            //      We instead want the store to have an Acquire barrier of sorts, which is what SeqCst provides.
            const task = new_task orelse {
                if (new_tail != tail) {
                    @atomicStore(usize, &self.runq_tail, new_tail, .SeqCst);
                    head = @atomicLoad(usize, &self.runq_head, .Monotonic);
                    tail = new_tail;
                    continue;
                } else {
                    break;
                }
            };

            // .Unordered stores are required when writing to our runq to avoid LLVM UB on stealer Threads.
            if (first_task == null) {
                first_task = task;
            } else {
                @atomicStore(*Task, &self.runq_buffer[new_tail % self.runq_buffer.len], task, .Unordered);
                new_tail +%= 1;
            }
        }

        // finished polling the thread pool's run queue.
        // release the IS_POLLING lock while at the same time updating the runq_tail.
        @atomicStore(usize, &pool.runq_tail, @ptrToInt(runq_tail), .Release);
        return first_task;
    }

    /// Mark a batch of tasks as runnable to the scheduler
    fn schedule(self: *Thread, tasks: Task.Batch) void {
        var batch = tasks;
        const pool = self.pool;
        
        var tail = self.runq_tail;
        var head = @atomicLoad(usize, &self.runq_head, .Monotonic);
        while (true) {

            const size = tail -% head;
            if (size > self.runq_buffer.len)
                std.debug.panic("Thread.schedule() with invalid runq size of {}", .{size});

            // check if theres space in the local runq buffer to push the batch tasks to
            if (batch.len <= (self.runq_buffer.len - size)) {
                var new_tail = tail;
                while (new_tail -% head < self.runq_buffer.len) {
                    task = batch.pop() orelse break;
                    @atomicStore(*Task, &self.runq_buffer[new_tail % self.runq_buffer.len], task, .Unordered);
                    new_tail +%= 1;
                }

                // only do a store if tasks were pushed to the runq buffer.
                // Release barrier to ensure stealer Threads read value Tasks from our runq_buffer.
                if (new_tail != tail) {
                    tail = new_tail;
                    @atomicStore(usize, &self.runq_tail, new_tail, .Release);
                }

                // handle the remaining batch tasks if there are any.
                if (batch.len == 0) {
                    break;
                } else {
                    head = @atomicLoad(usize, &self.runq_head, .Monotonic);
                    continue;
                }
            }

            // The batch hash more tasks than the runq buffer could affort to take.
            // try to steal half of the buffers tasks in order to overflow them into the pool runq.
            var steal: usize = self.runq_buffer.len / 2;
            if (@cmpxchgWeak(
                usize,
                &self.runq_head,
                head,
                head +% steal,
                .Monotonic,
                .Monotonic,
            )) |new_head| {
                head = new_head;
                continue;
            }

            // Create a batch of tasks out of those stolen from the local runq buffer.
            var overflow_batch = Task.Batch{};
            while (steal != 0) : (steal -= 1) {
                overflow_batch.pushBack(self.runq_buffer[head % self.runq_buffer.len]);
                head +%= 1;
            }

            // Combine the local runq batch and the scheduled batch, then push them all to the pool.
            overflow_batch.pushBackMany(batch);
            pool.push(overflow_batch);
            break;
        }

        // Tasks were scheduled into either our Thread or our Pool.
        // Try to wake up another thread in order to handle these new tasks.
        pool.resumeThread(.{});
    }
};