#ifndef __MPIPEDEFERRED_INCLUDE__
// Upgrade NOTE: excluded shader from OpenGL ES 2.0 because it uses non-square matrices
#pragma exclude_renderers gles
#define __MPIPEDEFERRED_INCLUDE__

#define UNITY_PASS_DEFERRED
#include "UnityStandardUtils.cginc"
#include "Lighting.cginc"
#include "DecalShading.cginc"
#include "Shader_Include/ImageBasedLighting.hlsl"
#include "Terrain.cginc"
#include "Tessellation.cginc"

#define GetScreenPos(pos) ((float2(pos.x, pos.y) * 0.5) / pos.w + 0.5)

float4 ProceduralStandardSpecular_Deferred (inout SurfaceOutputStandardSpecular s, out float4 outGBuffer0, out float4 outGBuffer1, out float4 outGBuffer2)
{
    // energy conservation
    float oneMinusReflectivity;
    s.Albedo = EnergyConservationBetweenDiffuseAndSpecular (s.Albedo, s.Specular, /*out*/ oneMinusReflectivity);
    // RT0: diffuse color (rgb), occlusion (a) - sRGB rendertarget
    outGBuffer0 = float4(s.Albedo, s.Occlusion);

    // RT1: spec color (rgb), smoothness (a) - sRGB rendertarget
    outGBuffer1 = float4(s.Specular, s.Smoothness);

    // RT2: normal (rgb), --unused, very low precision-- (a)

    outGBuffer2 = float4(s.Normal * 0.5f + 0.5f, 1);


		float4 emission = float4(s.Emission, 1);
    return emission;
}
float4x4 _LastVp;
float4x4 _NonJitterVP;
float3 _SceneOffset;
float2 _HeightScaleOffset;

struct InternalTessInterp_appdata_full {
  float4 pos : INTERNALTESSPOS;
  float2 pack0 : TEXCOORD0; 
	float3 screenUV : TEXCOORD1;
	nointerpolation uint2 vtUV : TEXCOORD3;
	#ifdef DEBUG_QUAD_TREE
	nointerpolation float scale : TEXCOORD4;
	#endif
};

struct v2f_surf {
  UNITY_POSITION(pos);
  float2 pack0 : TEXCOORD0; 
	float3 screenUV : TEXCOORD1;
	float3 worldPos : TEXCOORD2;
	nointerpolation uint2 vtUV : TEXCOORD3;
	#ifdef DEBUG_QUAD_TREE
	nointerpolation float scale : TEXCOORD4;
	#endif
};
struct UnityTessellationFactors {
    float edge[3] : SV_TessFactor;
    float inside : SV_InsideTessFactor;
};

InternalTessInterp_appdata_full tessvert_surf (uint instanceID : SV_INSTANCEID, uint vertexID : SV_VERTEXID) 
{
	Terrain_Appdata v = GetTerrain(instanceID, vertexID);
  	InternalTessInterp_appdata_full o;
  	o.pack0 = v.uv;
		o.vtUV = v.vtUV;
  	o.pos = float4(v.position, 1);
/*		#if UNITY_UV_STARTS_AT_TOP
		o.pos.y = -o.pos.y;
		#endif*/
	o.screenUV = ComputeScreenPos(o.pos).xyw;
	#ifdef DEBUG_QUAD_TREE
	o.scale = v.scale;
	#endif
  	return o;
}


inline UnityTessellationFactors hsconst_surf (InputPatch<InternalTessInterp_appdata_full,3> v) {
  UnityTessellationFactors o;

  o.edge[0] = 63;
  o.edge[1] = 63;
  o.edge[2] = 63;
  o.inside = 63;

  return o;
}

[UNITY_domain("tri")]
[UNITY_partitioning("fractional_odd")]
[UNITY_outputtopology("triangle_cw")]
[UNITY_patchconstantfunc("hsconst_surf")]
[UNITY_outputcontrolpoints(3)]
inline InternalTessInterp_appdata_full hs_surf (InputPatch<InternalTessInterp_appdata_full,3> v, uint id : SV_OutputControlPointID) {
  return v[id];
}


[UNITY_domain("tri")]
inline v2f_surf ds_surf (UnityTessellationFactors tessFactors, const OutputPatch<InternalTessInterp_appdata_full,3> vi, float3 bary : SV_DomainLocation) {
  v2f_surf o;
  float4 worldPos =  vi[0].pos*bary.x + vi[1].pos*bary.y + vi[2].pos*bary.z;
  worldPos.y += _HeightScaleOffset.y;
o.screenUV = vi[0].screenUV*bary.x + vi[1].screenUV*bary.y + vi[2].screenUV*bary.z;
o.pack0 = vi[0].pack0*bary.x + vi[1].pack0*bary.y + vi[2].pack0*bary.z;
o.vtUV = vi[0].vtUV;
o.pos= mul(UNITY_MATRIX_VP, worldPos);
o.worldPos = worldPos.xyz;
#ifdef DEBUG_QUAD_TREE
o.scale = vi[0].scale;
#endif
return o;
}

void frag_surf (v2f_surf IN,
		out float4 outGBuffer0 : SV_Target0,
    out float4 outGBuffer1 : SV_Target1,
    out float4 outGBuffer2 : SV_Target2,
    out float4 outEmission : SV_Target3,
	out float2 outMotionVector : SV_TARGET4
) {
	
  // prepare and unpack data
	float depth = IN.pos.z;
	float linearEye = LinearEyeDepth(depth);
	float2 screenUV = IN.screenUV.xy / IN.screenUV.z;
  float3 worldPos = IN.worldPos;
  float4 nonJitterScreenUV = ComputeScreenPos(mul(_NonJitterVP, float4(worldPos, 1)));
  nonJitterScreenUV.xy /= nonJitterScreenUV.w;
  float4 lastClip = ComputeScreenPos(mul(_LastVp, float4(worldPos, 1)));
  lastClip.xy /= lastClip.w;
  float4 velocity = float4(nonJitterScreenUV.xy, lastClip.xy);
	#if UNITY_UV_STARTS_AT_TOP
				outMotionVector = velocity.xw - velocity.zy;
#else
				outMotionVector =  velocity.xy - velocity.zw;
#endif
  float3 worldViewDir = normalize(_WorldSpaceCameraPos - worldPos.xyz);
  SurfaceOutputStandardSpecular o;
  float3x3 wdMatrix= float3x3(float3(1, 0, 0), float3(0, 0, 1), float3(0, 1, 0));
  // call surface function
  surf (IN.pack0.xy, IN.vtUV, o);
  o.Normal = normalize(mul(o.Normal, wdMatrix));
  outEmission = ProceduralStandardSpecular_Deferred (o, outGBuffer0, outGBuffer1, outGBuffer2); //GI neccessary here!


	#ifdef LIT_ENABLE
	float Roughness = clamp(1 - outGBuffer1.a, 0.02, 1);
					  float3 multiScatter;
  					float3 preint = PreintegratedDGF_LUT(_PreIntDefault, multiScatter, outGBuffer1.xyz, Roughness, dot(o.Normal, worldViewDir));
					  outGBuffer1.xyz *= multiScatter;
					
					GeometryBuffer buffer;
					buffer.AlbedoColor = outGBuffer0.rgb;
					buffer.SpecularColor = outGBuffer1.rgb;
					buffer.Roughness = Roughness;
					[branch]
					if(dot(_LightEnabled.zw, 1) > 0.5)
                    	outEmission.xyz += max(0, CalculateLocalLight(screenUV, float4(worldPos,1 ), linearEye, o.Normal, worldViewDir, buffer));
[branch]
if(_LightEnabled.x > 0.5){
	[branch]
if(_LightEnabled.y > 0.5)
					outEmission.xyz +=max(0,  CalculateSunLight(o.Normal, depth, float4(worldPos,1 ), worldViewDir, buffer));
else
					outEmission.xyz +=max(0,  CalculateSunLight_NoShadow(o.Normal, worldViewDir, buffer));
}
					outGBuffer1.xyz = preint * multiScatter;
#endif
}

/////////////
//Shadow pass
/////////////
float4x4 _ShadowMapVP;
			struct appdata_shadow
			{
				float4 vertex : POSITION;
				#if CUT_OFF
				float2 texcoord : TEXCOORD0;
				#endif
			};
			struct v2f_shadow
			{
				float4 vertex : SV_POSITION;
				#if POINT_LIGHT_SHADOW
				float3 worldPos : TEXCOORD1;
				#endif
				#if CUT_OFF
				float2 texcoord : TEXCOORD0;
				#endif
			};

			v2f_shadow vert_shadow (uint instanceID : SV_INSTANCEID, uint vertexID : SV_VERTEXID) 
			{
				Terrain_Appdata v = GetTerrain(instanceID, vertexID);
				v2f_shadow o;
				#if POINT_LIGHT_SHADOW
				o.worldPos = v.position;
				#endif
				o.vertex = mul(_ShadowMapVP, float4(v.position, 1));
				#if CUT_OFF
				o.texcoord = TRANSFORM_TEX(v.texcoord, _MainTex);
				#endif
				return o;
			}

			
			float frag_shadow (v2f_shadow i)  : SV_TARGET
			{
				#if CUT_OFF
				float4 c = tex2D(_MainTex, i.texcoord);
				clip(c.a * _Color.a - _Cutoff);
				#endif
				#if POINT_LIGHT_SHADOW
				return distance(i.worldPos, _LightPos.xyz) / _LightPos.w;
				#else
				return i.vertex.z;
				#endif
			}
#endif