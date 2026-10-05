// library_kx.js — bibliothèque JS emscripten : collecte des rapports Zig.
addToLibrary({
    kx_report: function (tag_ptr, tag_len, json_ptr, json_len) {
        var tag = UTF8ToString(tag_ptr, tag_len);
        var json = UTF8ToString(json_ptr, json_len);
        (Module['__results'] = Module['__results'] || []).push({ tag: tag, json: json });
        if (Module['onKxReport']) Module['onKxReport'](tag, json);
    },
});
