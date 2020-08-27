// Copyright (c) 2020 kprotty
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// 	http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

const std = @import("std");
const zap = @import("../zap.zig");

pub fn Channel(comptime T: type) type {
    const Lock = struct {
        const Self = @This();

        inner: std.Mutex = std.Mutex{},

        fn acquire(self: *Self) void {
            _ = self.inner.acquire();
        }

        fn release(self: *Self) void {
            (std.Mutex.Held{ .mutex = &self.inner }).release();
        }
    };
    
    return struct {
        const Self = @This();

        lock: Lock = Lock{},
        getters: ?*Waiter = null,
        putters: ?*Waiter = null,
        head: usize = 0,
        tail: usize = 0,
        buffer_ptr: ?[*]T,
        buffer_len: usize,

        const Waiter = struct {
            task: zap.Task,
            next: ?*Waiter,
            last: *Waiter,
            state: State,

            const State = union(enum) {
                item: T,
                none: void,
                closed: void,
            };
        };

        pub fn init(buffer: []T) Self {
            return Self{
                .buffer_ptr = buffer.ptr,
                .buffer_len = buffer.len,
            };
        }

        pub fn deinit(self: *Self) void {
            self.close();
        }

        pub fn close(self: *Self) void {
            var waiters: ?*Waiter = null;
            
            {
                self.lock.acquire();
                defer self.lock.release();

                waiters = self.putters;
                if (self.getters) |getter_head| {
                    if (waiters) |head| {
                        head.last.next = getter_head;
                        head.last = getter_head.last;
                    } else {
                        waiters = getter_head;
                    }
                }

                self.buffer_ptr = null;
                self.head = 0;
                self.tail = 0;

                self.putters = null;
                self.getters = null;
            }

            var batch = zap.Task.Batch{};
            while (waiters) |idle_waiter| {
                const waiter = idle_waiter;
                waiters = waiter.next;
                waiter.state = Waiter.State{ .closed = {} };
                batch.push(&waiter.task);
            }

            batch.schedule();
        }

        pub fn put(self: *Self, item: T) error{Closed}!void {
            self.lock.acquire();

            const buffer_ptr = self.buffer_ptr orelse return error.Closed;

            if (self.getters) |getter_head| {
                const waiter = getter_head;
                self.getters = waiter.next;
                self.lock.release();

                waiter.state = Waiter.State{ .item = item };
                suspend {
                    var task = zap.Task.init(@frame());
                    waiter.task.scheduleNext();
                    task.schedule();
                }
                return;
            }

            if (self.tail -% self.head < self.buffer_len) {
                buffer_ptr[self.tail % self.buffer_len] = item;
                self.tail +%= 1;
                self.lock.release();
                return;
            }

            var waiter: Waiter = undefined;
            waiter.task = zap.Task.init(@frame());
            waiter.next = null;
            waiter.last = &waiter;
            waiter.state = Waiter.State{ .item = item };

            if (self.putters) |putter_head| {
                putter_head.last.next = &waiter;
                putter_head.last = &waiter; 
            } else {
                self.putters = &waiter;
            }

            suspend {
                self.lock.release();
            }

            return switch (waiter.state) {
                .item => unreachable,
                .none => {},
                .closed => error.Closed,
            };
        }

        pub fn get(self: *Self) error{Closed}!T {
            self.lock.acquire();

            const buffer_ptr = self.buffer_ptr orelse return error.Closed;

            if (self.putters) |putter_head| {
                const waiter = putter_head;
                self.putters = waiter.next;
                self.lock.release();

                const item = switch (waiter.state) {
                    .item => |item| item,
                    else => unreachable,
                };

                waiter.state = Waiter.State{ .none = {} };
                waiter.task.schedule();
                return item;
            }

            if (self.tail != self.head) {
                const item = buffer_ptr[self.head % self.buffer_len];
                self.head +%= 1;
                self.lock.release();
                return item;
            }

            var waiter: Waiter = undefined;
            waiter.task = zap.Task.init(@frame());
            waiter.next = null;
            waiter.last = &waiter;
            waiter.state = Waiter.State{ .none = {} };

            if (self.getters) |getter_head| {
                getter_head.last.next = &waiter;
                getter_head.last = &waiter; 
            } else {
                self.getters = &waiter;
            }

            suspend {
                self.lock.release();
            }

            return switch (waiter.state) {
                .item => |item| item,
                .closed => error.Closed,
                else => unreachable,
            };
        }
    };
}