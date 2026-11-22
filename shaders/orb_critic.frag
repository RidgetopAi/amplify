#version 440
#extension GL_GOOGLE_include_directive : enable
// Desktop orb, critic role program (decision 23973614: one program per role).
// Body in orbbody.glsl; compiled to plugin/shaders/orb_critic.frag.qsb.
#define ROLE 2
#include "orbbody.glsl"
