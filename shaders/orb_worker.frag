#version 440
#extension GL_GOOGLE_include_directive : enable
// Desktop orb, worker role program (decision 23973614: one program per role).
// Body in orbbody.glsl; compiled to plugin/shaders/orb_worker.frag.qsb.
#define ROLE 1
#include "orbbody.glsl"
