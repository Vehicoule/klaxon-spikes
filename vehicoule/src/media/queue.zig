//! Queue de lecture minimale (spec V0) : items ordonnés de MediaSource +
//! titre affiché ; index courant ; avance/recule avec park en fin de file.
//! Aucun drain automatique passé le dernier item.

const std = @import("std");
const MediaSource = @import("source.zig").MediaSource;

pub const Item = struct {
    source: MediaSource,
    title: []const u8,
};

pub const Queue = struct {
    items: std.ArrayList(Item) = .empty,
    index: ?usize = null, // item en lecture ; null = rien chargé

    pub fn len(self: *const Queue) usize {
        return self.items.items.len;
    }

    pub fn current(self: *const Queue) ?*const Item {
        const i = self.index orelse return null;
        if (i >= self.len()) return null;
        return &self.items.items[i];
    }

    /// null en début de file : l'appelant ne recycle pas.
    pub fn prev(self: *Queue) ?*const Item {
        const i = self.index orelse return null;
        if (i == 0) return null;
        self.index = i - 1;
        return self.current();
    }

    /// null en fin de file : la session se park sur .ended, pas de boucle.
    pub fn next(self: *Queue) ?*const Item {
        const i = self.index orelse return null;
        if (i + 1 >= self.len()) return null;
        self.index = i + 1;
        return self.current();
    }

    pub fn jump(self: *Queue, i: usize) ?*const Item {
        if (i >= self.len()) return null;
        self.index = i;
        return self.current();
    }

    pub fn deinit(self: *Queue, alloc: std.mem.Allocator) void {
        self.items.deinit(alloc);
    }
};
