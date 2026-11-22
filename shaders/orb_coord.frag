#version 440
#extension GL_GOOGLE_include_directive : enable
// Desktop orb, coord role program (decision 23973614: one program per role).
// Body in orbbody.glsl; compiled to plugin/shaders/orb_coord.frag.qsb.
#define ROLE 0
#include "orbbody.glsl"
