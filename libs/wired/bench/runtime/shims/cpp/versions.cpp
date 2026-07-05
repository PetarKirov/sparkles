// Engine/version provenance for the bench report header.

#include "wired_bench_shim.h"

#include <rapidjson/rapidjson.h>
#include <simdjson.h>

#include <string>

extern "C" const char *jb_cpp_versions(void)
{
    static const std::string versions = [] {
        std::string s = "simdjson " SIMDJSON_VERSION " (";
        s += simdjson::get_active_implementation()->name();
        s += " kernel); rapidjson " RAPIDJSON_VERSION_STRING;
        return s;
    }();
    return versions.c_str();
}
