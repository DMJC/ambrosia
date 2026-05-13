#import "Ambrosia3DBackground.h"

#import <AppKit/AppKit.h>

#include <wlr/util/log.h>
#include <wlr/interfaces/wlr_buffer.h>
#include <cairo/cairo.h>
#include <drm/drm_fourcc.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>

#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <stdint.h>

/* -------------------------------------------------------------------------
 * Math utilities (ported from 3D_Space_Desktop/main.m)
 * ---------------------------------------------------------------------- */

typedef struct { float x, y, z; } Vec3;

#define VIEW_FOV_Y_DEG  75.0f
#define VIEW_NEAR_PLANE  1.0f
#define VIEW_FAR_PLANE   50000.0f

static inline float DegToRad3D(float d)  { return d * (float)M_PI / 180.0f; }

static inline Vec3 V3Normalize(Vec3 v)
{
    float len = sqrtf(v.x*v.x + v.y*v.y + v.z*v.z);
    if (len < 1e-6f) return (Vec3){0,1,0};
    return (Vec3){v.x/len, v.y/len, v.z/len};
}
static inline Vec3 V3Cross(Vec3 a, Vec3 b)
{
    return (Vec3){a.y*b.z-a.z*b.y, a.z*b.x-a.x*b.z, a.x*b.y-a.y*b.x};
}
static inline Vec3 V3RotX(Vec3 v, float d)
{
    float c=cosf(DegToRad3D(d)), s=sinf(DegToRad3D(d));
    return (Vec3){v.x, v.y*c-v.z*s, v.y*s+v.z*c};
}
static inline Vec3 V3RotY(Vec3 v, float d)
{
    float c=cosf(DegToRad3D(d)), s=sinf(DegToRad3D(d));
    return (Vec3){v.x*c+v.z*s, v.y, -v.x*s+v.z*c};
}
static inline Vec3 V3RotZ(Vec3 v, float d)
{
    float c=cosf(DegToRad3D(d)), s=sinf(DegToRad3D(d));
    return (Vec3){v.x*c-v.y*s, v.x*s+v.y*c, v.z};
}
static inline Vec3 V3RotXYZ(Vec3 v, Vec3 e)
{
    return V3RotZ(V3RotY(V3RotX(v, e.x), e.y), e.z);
}

typedef struct { float m[16]; } Mat4;

static inline Mat4 Mat4Identity(void)
{
    Mat4 r = {{0}}; r.m[0]=r.m[5]=r.m[10]=r.m[15]=1.0f; return r;
}
static inline Mat4 Mat4Mul(Mat4 a, Mat4 b)
{
    Mat4 r;
    for (int c=0;c<4;c++) for (int row=0;row<4;row++) {
        float s=0; for (int k=0;k<4;k++) s+=a.m[k*4+row]*b.m[c*4+k];
        r.m[c*4+row]=s;
    }
    return r;
}
static inline Mat4 Mat4Translate(float x, float y, float z)
{
    Mat4 r=Mat4Identity(); r.m[12]=x; r.m[13]=y; r.m[14]=z; return r;
}
static inline Mat4 Mat4RotateX(float d)
{
    float c=cosf(DegToRad3D(d)), s=sinf(DegToRad3D(d));
    Mat4 r=Mat4Identity(); r.m[5]=c; r.m[6]=s; r.m[9]=-s; r.m[10]=c; return r;
}
static inline Mat4 Mat4RotateY(float d)
{
    float c=cosf(DegToRad3D(d)), s=sinf(DegToRad3D(d));
    Mat4 r=Mat4Identity(); r.m[0]=c; r.m[2]=-s; r.m[8]=s; r.m[10]=c; return r;
}
static inline Mat4 Mat4RotateZ(float d)
{
    float c=cosf(DegToRad3D(d)), s=sinf(DegToRad3D(d));
    Mat4 r=Mat4Identity(); r.m[0]=c; r.m[1]=s; r.m[4]=-s; r.m[5]=c; return r;
}
static inline Mat4 Mat4Frustum(float l, float ri, float b, float t, float n, float f)
{
    Mat4 mat={{0}};
    mat.m[0]=2.0f*n/(ri-l); mat.m[5]=2.0f*n/(t-b);
    mat.m[8]=(ri+l)/(ri-l); mat.m[9]=(t+b)/(t-b);
    mat.m[10]=-(f+n)/(f-n); mat.m[11]=-1.0f;
    mat.m[14]=-2.0f*f*n/(f-n);
    return mat;
}

/* -------------------------------------------------------------------------
 * Binary helpers
 * ---------------------------------------------------------------------- */
static uint32_t U32(const uint8_t *p) {
    return ((uint32_t)p[0])|((uint32_t)p[1]<<8)|((uint32_t)p[2]<<16)|((uint32_t)p[3]<<24);
}
static uint16_t U16(const uint8_t *p) {
    return ((uint16_t)p[0])|((uint16_t)p[1]<<8);
}
static float F32(const uint8_t *p) { float f; memcpy(&f,p,4); return f; }
static NSString *FourCCStr(const uint8_t *p) { char s[5]={0}; memcpy(s,p,4); return [NSString stringWithUTF8String:s]; }
static NSString *BStr(const uint8_t *b, NSUInteger n) {
    NSMutableString *m=[NSMutableString string];
    for (NSUInteger i=0;i<n&&b[i];i++) if(b[i]>=32&&b[i]<127) [m appendFormat:@"%c",b[i]];
    return m;
}
static BOOL BoundsOK(NSUInteger off, NSUInteger need, NSUInteger end) {
    return off<=end && need<=end-off;
}

/* -------------------------------------------------------------------------
 * Scene data structures (ARC versions of main.m classes)
 * ---------------------------------------------------------------------- */

@interface A3DSceneModel : NSObject
@property(nonatomic, copy)   NSString *pofPath;
@property(nonatomic)         Vec3      position;
@property(nonatomic)         Vec3      rotationDeg;
@property(nonatomic)         BOOL      hasOvalPath;
@property(nonatomic)         float     ovalRadius;
@property(nonatomic)         float     ovalSpeedDegPerSec;
@property(nonatomic)         float     ovalAngleOffset;
@property(nonatomic)         Vec3      ovalPlaneRot;
@property(nonatomic)         BOOL      ovalRev;
@property(nonatomic)         BOOL      rotSync;
@property(nonatomic)         BOOL      rotRev;
@end
@implementation A3DSceneModel @end

@interface A3DSceneDef : NSObject
@property(nonatomic)         Vec3              cameraPosition;
@property(nonatomic, copy)   NSString         *textureRoot;
@property(nonatomic, copy)   NSString         *skyboxName;
@property(nonatomic)         BOOL              showLoops;
@property(nonatomic, strong) NSMutableArray   *models;
@property(nonatomic)         Vec3              sunDir;
@end
@implementation A3DSceneDef
- (instancetype)init {
    if ((self=[super init])) {
        _cameraPosition=(Vec3){0,0,8000};
        _models=[NSMutableArray array];
        _sunDir=V3Normalize((Vec3){1,1,1});
    }
    return self;
}
@end

/* POF data */
typedef struct { Vec3 p[3]; float uv[3][2]; int texIndex; } A3DPOFTri;
typedef struct { GLuint vao, vbo; GLsizei count; int texIndex; } A3DVBOBatch;

@interface A3DPOFSub : NSObject
@property(nonatomic)         int           sid;
@property(nonatomic)         int           parent;
@property(nonatomic)         Vec3          offset;
@property(nonatomic)         Vec3          center;
@property(nonatomic, strong) NSMutableData *tris;
@property(nonatomic, strong) NSMutableData *glow;
@property(nonatomic)         BOOL          hasUVStats;
@property(nonatomic)         float         uvMinU, uvMaxU, uvMinV, uvMaxV;
@property(nonatomic)         BOOL          rotates;
@property(nonatomic)         int           movementType;
@property(nonatomic)         int           movementAxis;
@property(nonatomic)         float         spin;
@property(nonatomic, strong) NSMutableData *vboBatches;
@property(nonatomic)         BOOL          vbosBuilt;
@property(nonatomic, copy)   NSString     *tex;
@property(nonatomic, copy)   NSString     *name;
@end
@implementation A3DPOFSub
- (instancetype)init {
    if ((self=[super init])) { _uvMinU=_uvMinV=999999.0f; _uvMaxU=_uvMaxV=-999999.0f; }
    return self;
}
@end

@interface A3DPOFMesh : NSObject
@property(nonatomic, strong) NSMutableArray *subs;
@property(nonatomic, strong) NSMutableArray *textures;
@end
@implementation A3DPOFMesh @end

/* -------------------------------------------------------------------------
 * Animated texture sequence
 * ---------------------------------------------------------------------- */
@interface A3DEffAnim : NSObject
@property(nonatomic, strong) NSArray *frames;
@property(nonatomic) float fps;
- (GLuint)frameAtTime:(float)t;
@end
@implementation A3DEffAnim
- (GLuint)frameAtTime:(float)t {
    NSUInteger n=_frames.count; if(!n) return 0;
    return (GLuint)[[_frames objectAtIndex:(NSUInteger)(fabsf(t)*_fps)%n] unsignedIntValue];
}
@end

@interface A3DTexMat : NSObject
@property(nonatomic) GLuint diffuse, glow, normal, shine;
@property(nonatomic, strong) A3DEffAnim *diffuseAnim, *glowAnim, *normalAnim, *shineAnim;
@property(nonatomic, copy) NSString *baseName, *diffusePath, *glowPath, *normalPath, *shinePath;
@end
@implementation A3DTexMat @end

/* -------------------------------------------------------------------------
 * Scene parser
 * ---------------------------------------------------------------------- */
static NSString *NormPath(NSString *raw) {
    return [[raw stringByReplacingOccurrencesOfString:@"\\\\ " withString:@" "]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

static A3DSceneDef *ParseScene(NSString *path, NSError **err) {
    NSString *raw = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:err];
    if (!raw) return nil;
    A3DSceneDef *s = [A3DSceneDef new];
    NSString *dir = [path stringByDeletingLastPathComponent];
    for (NSString *lr in [raw componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *line = [[[[lr componentsSeparatedByString:@"#"] objectAtIndex:0]
                           stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] copy];
        if (!line.length) continue;
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location==NSNotFound) continue;
        NSString *k = [[[line substringToIndex:eq.location] lowercaseString]
                       stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *v = NormPath([line substringFromIndex:eq.location+1]);
        if ([k isEqualToString:@"camera"]) {
            NSArray *c=[v componentsSeparatedByString:@","];
            if (c.count>=3) s.cameraPosition=(Vec3){[c[0] floatValue],[c[1] floatValue],[c[2] floatValue]};
        } else if ([k isEqualToString:@"textureroot"]) {
            s.textureRoot = [v isAbsolutePath] ? v : [dir stringByAppendingPathComponent:v];
        } else if ([k isEqualToString:@"skybox"]) {
            s.skyboxName = v.length ? v : nil;
        } else if ([k isEqualToString:@"showloops"]) {
            s.showLoops = [[v lowercaseString] isEqualToString:@"true"];
        } else if ([k isEqualToString:@"sun"]) {
            NSArray *c=[v componentsSeparatedByString:@","];
            if (c.count>=3) {
                Vec3 d={(float)[c[0] doubleValue],(float)[c[1] doubleValue],(float)[c[2] doubleValue]};
                s.sunDir = V3Normalize(d);
            }
        } else if ([k isEqualToString:@"model"]) {
            NSArray *ch=[v componentsSeparatedByString:@","];
            if (ch.count<4) continue;
            A3DSceneModel *m=[A3DSceneModel new];
            NSString *mp=NormPath(ch[0]);
            m.pofPath = [mp isAbsolutePath] ? mp : [dir stringByAppendingPathComponent:mp];
            m.position=(Vec3){[ch[1] floatValue],[ch[2] floatValue],[ch[3] floatValue]};
            for (NSUInteger i=4;i<ch.count;i++) {
                NSString *item=[[[ch[i] lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] copy];
                NSArray *kv=[item componentsSeparatedByString:@"="];
                if (kv.count!=2) continue;
                NSString *kk=kv[0], *vv=kv[1];
                if ([kk isEqualToString:@"ovalpath"]) m.hasOvalPath=[vv isEqualToString:@"true"];
                else if ([kk isEqualToString:@"radius"]) m.ovalRadius=[vv floatValue];
                else if ([kk isEqualToString:@"speed"]) m.ovalSpeedDegPerSec=[vv floatValue];
                else if ([kk isEqualToString:@"offset"]) m.ovalAngleOffset=[vv floatValue];
                else if ([kk isEqualToString:@"rotx"]) m.rotationDeg=(Vec3){[vv floatValue],m.rotationDeg.y,m.rotationDeg.z};
                else if ([kk isEqualToString:@"roty"]) m.rotationDeg=(Vec3){m.rotationDeg.x,[vv floatValue],m.rotationDeg.z};
                else if ([kk isEqualToString:@"rotz"]) m.rotationDeg=(Vec3){m.rotationDeg.x,m.rotationDeg.y,[vv floatValue]};
                else if ([kk isEqualToString:@"ovalrotx"]) m.ovalPlaneRot=(Vec3){[vv floatValue],m.ovalPlaneRot.y,m.ovalPlaneRot.z};
                else if ([kk isEqualToString:@"ovalroty"]) m.ovalPlaneRot=(Vec3){m.ovalPlaneRot.x,[vv floatValue],m.ovalPlaneRot.z};
                else if ([kk isEqualToString:@"ovalrotz"]) m.ovalPlaneRot=(Vec3){m.ovalPlaneRot.x,m.ovalPlaneRot.y,[vv floatValue]};
                else if ([kk isEqualToString:@"ovalrev"]) m.ovalRev=[vv intValue]!=0;
                else if ([kk isEqualToString:@"rotsync"]) m.rotSync=[vv intValue]!=0;
                else if ([kk isEqualToString:@"rotrev"]) m.rotRev=[vv intValue]!=0;
            }
            [s.models addObject:m];
        }
    }
    if (!s.textureRoot.length) s.textureRoot=dir;
    return s;
}

/* -------------------------------------------------------------------------
 * POF loading (ported from main.m)
 * ---------------------------------------------------------------------- */
static BOOL ReadBPOFStr(const uint8_t *b, NSUInteger *io, NSUInteger end, NSString **out) {
    if (!BoundsOK(*io,4,end)) return NO;
    uint32_t len=U32(b+*io); *io+=4;
    if (!BoundsOK(*io,len,end)) return NO;
    *out=BStr(b+*io,len); *io+=len; return YES;
}
static void UVStat(A3DPOFSub *s, float u, float v) {
    if(u<s.uvMinU)s.uvMinU=u; if(u>s.uvMaxU)s.uvMaxU=u;
    if(v<s.uvMinV)s.uvMinV=v; if(v>s.uvMaxV)s.uvMaxV=v;
    s.hasUVStats=YES;
}
static void AppendTri(A3DPOFSub *sub, NSMutableData *dst,
                      Vec3 a,float au,float av, Vec3 b,float bu,float bv,
                      Vec3 c,float cu,float cv, int ti)
{
    UVStat(sub,au,av); UVStat(sub,bu,bv); UVStat(sub,cu,cv);
    A3DPOFTri t;
    t.p[0]=a; t.uv[0][0]=au; t.uv[0][1]=av;
    t.p[1]=b; t.uv[1][0]=bu; t.uv[1][1]=bv;
    t.p[2]=c; t.uv[2][0]=cu; t.uv[2][1]=cv;
    t.texIndex=ti;
    [dst appendBytes:&t length:sizeof(t)];
}
static BOOL ParseDEFPOINTS(const uint8_t *b,NSUInteger pos,NSUInteger end,NSMutableArray *pts) {
    if(!BoundsOK(pos,20,end)) return NO;
    uint32_t op=U32(b+pos),len=U32(b+pos+4);
    if(op!=1||len<20||!BoundsOK(pos,len,end)) return NO;
    NSUInteger d=pos+8, opEnd=pos+len;
    uint32_t nv=U32(b+d),nn=U32(b+d+4),dataOff=U32(b+d+8);
    (void)nn;
    if(nv==0||nv>65535) return NO;
    NSUInteger counts=d+12, q=pos+dataOff;
    if(!BoundsOK(counts,nv,opEnd)||!BoundsOK(q,0,opEnd)) return NO;
    [pts removeAllObjects];
    for(uint32_t i=0;i<nv;i++) {
        if(!BoundsOK(q,12,opEnd)) return NO;
        Vec3 v={F32(b+q),F32(b+q+4),F32(b+q+8)}; q+=12;
        NSUInteger nb=(NSUInteger)b[counts+i]*12;
        if(!BoundsOK(q,nb,opEnd)) return NO;
        q+=nb;
        [pts addObject:[NSData dataWithBytes:&v length:sizeof(Vec3)]];
    }
    return pts.count>0;
}
static BOOL ParseFlatPoly(const uint8_t *b,NSUInteger pos,NSUInteger end,NSArray *pts,A3DPOFSub *s) {
    if(!BoundsOK(pos,44,end)) return NO;
    uint32_t op=U32(b+pos),len=U32(b+pos+4);
    if(op!=2||len<44||!BoundsOK(pos,len,end)) return NO;
    NSUInteger d=pos+8,opEnd=pos+len,q=d+36;
    uint32_t nv=U32(b+d+28);
    if(nv<3||nv>256||!BoundsOK(q,(NSUInteger)nv*4,opEnd)) return NO;
    Vec3 pv[256];
    for(uint32_t i=0;i<nv;i++) {
        uint16_t vi=U16(b+q); q+=4;
        if(vi>=pts.count) return NO;
        memcpy(&pv[i],((NSData *)pts[vi]).bytes,sizeof(Vec3));
    }
    for(uint32_t i=1;i+1<nv;i++)
        AppendTri(s,s.tris, pv[0],0,0, pv[i],0,0, pv[i+1],0,0, -1);
    return YES;
}
static BOOL ParseTmapPoly(const uint8_t *b,NSUInteger pos,NSUInteger end,NSArray *pts,A3DPOFSub *s) {
    if(!BoundsOK(pos,44,end)) return NO;
    uint32_t op=U32(b+pos),len=U32(b+pos+4);
    if(op!=3||len<44||!BoundsOK(pos,len,end)) return NO;
    NSUInteger d=pos+8,opEnd=pos+len,q=d+36;
    uint32_t nv=U32(b+d+28); int ti=(int)U32(b+d+32);
    if(nv<3||nv>256||!BoundsOK(q,(NSUInteger)nv*12,opEnd)) return NO;
    Vec3 pv[256]; float uv[256][2];
    for(uint32_t i=0;i<nv;i++) {
        uint16_t vi=U16(b+q); uv[i][0]=F32(b+q+4); uv[i][1]=F32(b+q+8); q+=12;
        if(vi>=pts.count) return NO;
        memcpy(&pv[i],((NSData *)pts[vi]).bytes,sizeof(Vec3));
    }
    for(uint32_t i=1;i+1<nv;i++)
        AppendTri(s,s.tris, pv[0],uv[0][0],uv[0][1], pv[i],uv[i][0],uv[i][1], pv[i+1],uv[i+1][0],uv[i+1][1], ti);
    return YES;
}
static void BSPCollect(const uint8_t *b, NSUInteger pos, NSUInteger start, NSUInteger end,
                       NSMutableSet *vis, NSMutableArray *pts, A3DPOFSub *s,
                       NSUInteger *dc, NSUInteger *fc, NSUInteger *tc, NSUInteger depth)
{
    if(depth>256||!BoundsOK(pos,8,end)) return;
    NSNumber *key=@(pos);
    if([vis containsObject:key]) return;
    [vis addObject:key];
    uint32_t op=U32(b+pos), len=U32(b+pos+4);
    if(op==0||len<8||!BoundsOK(pos,len,end)) return;
    if(op==1) { NSMutableArray *c=[NSMutableArray array]; if(ParseDEFPOINTS(b,pos,end,c)){[pts removeAllObjects];[pts addObjectsFromArray:c];(*dc)++;} }
    else if(op==2&&pts.count) { NSUInteger old=s.tris.length; if(ParseFlatPoly(b,pos,end,pts,s)&&s.tris.length>old)(*fc)++; }
    else if(op==3&&pts.count) { NSUInteger old=s.tris.length; if(ParseTmapPoly(b,pos,end,pts,s)&&s.tris.length>old)(*tc)++; }
    else if(op==4) {
        NSUInteger d=pos+8;
        if(BoundsOK(d,64-8,pos+len)) {
            int32_t off[5];
            off[0]=(int32_t)U32(b+d+28); off[1]=(int32_t)U32(b+d+32);
            off[2]=(int32_t)U32(b+d+36); off[3]=(int32_t)U32(b+d+40); off[4]=(int32_t)U32(b+d+44);
            for(int i=0;i<5;i++) { if(off[i]>0){ NSUInteger ch=pos+(NSUInteger)off[i]; if(ch>=start&&ch<end) BSPCollect(b,ch,start,end,vis,pts,s,dc,fc,tc,depth+1); } }
        }
    }
    NSUInteger next=pos+len;
    if(next>pos&&next<end) BSPCollect(b,next,start,end,vis,pts,s,dc,fc,tc,depth+1);
}
static BOOL ParseBSP(const uint8_t *b, NSUInteger start, NSUInteger size, A3DPOFSub *s) {
    NSUInteger end=start+size; if(end<start) return NO;
    NSMutableArray *pts=[NSMutableArray array];
    NSUInteger dc=0,fc=0,tc=0, before=s.tris.length/sizeof(A3DPOFTri);
    NSMutableSet *vis=[NSMutableSet set];
    BSPCollect(b,start,start,end,vis,pts,s,&dc,&fc,&tc,0);
    if(s.tris.length/sizeof(A3DPOFTri)==before) {
        pts=[NSMutableArray array]; vis=[NSMutableSet set]; NSUInteger pos=start;
        while(BoundsOK(pos,8,end)) { uint32_t op=U32(b+pos),len=U32(b+pos+4); if(op==0||len<8||!BoundsOK(pos,len,end)) break; BSPCollect(b,pos,start,end,vis,pts,s,&dc,&fc,&tc,0); pos+=len; }
    }
    return (s.tris.length/sizeof(A3DPOFTri))>before;
}
static A3DPOFMesh *LoadPOF(NSString *path, NSString **errOut) {
    NSData *d=[NSData dataWithContentsOfFile:path];
    if(!d||d.length<12) { if(errOut)*errOut=@"unreadable"; return nil; }
    const uint8_t *b=d.bytes;
    if(memcmp(b,"PSPO",4)!=0) { if(errOut)*errOut=@"bad signature"; return nil; }
    NSMutableArray *detail=[NSMutableArray array];
    NSMutableDictionary *objById=[NSMutableDictionary dictionary];
    NSMutableArray *textures=[NSMutableArray array];
    NSUInteger o=8;
    while(o+8<=d.length) {
        const uint8_t *chunk=b+o;
        NSString *cid=FourCCStr(chunk);
        uint32_t len=U32(chunk+4); NSUInteger p=o+8;
        if(p+len>d.length) break;
        if([cid isEqualToString:@"TXTR"]) {
            NSUInteger q=p;
            if(BoundsOK(q,4,p+len)) { uint32_t nt=U32(b+q); q+=4; for(uint32_t i=0;i<nt;i++) { NSString *t=@""; if(ReadBPOFStr(b,&q,p+len,&t)&&t.length)[textures addObject:t]; else break; } }
        } else if([cid isEqualToString:@"HDR2"]&&len>=40) {
            uint32_t nd=U32(b+p+36); NSUInteger q=p+40;
            for(uint32_t i=0;i<nd&&q+4<=p+len;i++,q+=4) [detail addObject:@((int)U32(b+q))];
        } else if([cid isEqualToString:@"OBJ2"]&&len>=76) {
            NSUInteger end2=p+len, q=p;
            A3DPOFSub *s=[A3DPOFSub new]; s.tris=[NSMutableData data]; s.glow=[NSMutableData data]; s.spin=20.0f;
            s.sid=(int)U32(b+q); q+=4; q+=4; /* skip radius */
            s.parent=(int)U32(b+q); q+=4;
            s.offset=(Vec3){F32(b+q),F32(b+q+4),F32(b+q+8)}; q+=12;
            s.center=(Vec3){F32(b+q),F32(b+q+4),F32(b+q+8)}; q+=12;
            q+=24; /* skip bbox */
            NSString *nm=@"", *props=@"";
            if(!ReadBPOFStr(b,&q,end2,&nm)) { objById[@(s.sid)]=s; o=p+len; continue; }
            s.name=nm;
            if(!ReadBPOFStr(b,&q,end2,&props)) { objById[@(s.sid)]=s; o=p+len; continue; }
            if(!BoundsOK(q,16,end2)) { objById[@(s.sid)]=s; o=p+len; continue; }
            s.movementType=(int)U32(b+q); q+=4;
            s.movementAxis=(int)U32(b+q); q+=4;
            q+=4; /* reserved */
            uint32_t bspSize=U32(b+q); q+=4;
            if(s.movementType>=0) {
                s.rotates=YES;
                NSRange rt=[[props lowercaseString] rangeOfString:@"$rotate="];
                if(rt.location!=NSNotFound) { float rate=[[props substringFromIndex:rt.location+rt.length] floatValue]; if(rate!=0.0f) s.spin=rate; }
            }
            if(!s.tex.length&&textures.count) s.tex=textures[0];
            if(BoundsOK(q,bspSize,end2)) ParseBSP(b,q,bspSize,s);
            objById[@(s.sid)]=s;
        }
        o=p+len;
    }
    A3DPOFMesh *m=[A3DPOFMesh new]; m.subs=[NSMutableArray array]; m.textures=textures;
    if(detail.count>0) {
        int lod0=[detail[0] intValue]; NSMutableSet *ids=[NSMutableSet set]; NSMutableArray *q=[NSMutableArray arrayWithObject:@(lod0)];
        while(q.count) { NSNumber *cur=q[0]; [q removeObjectAtIndex:0]; if([ids containsObject:cur])continue; [ids addObject:cur]; for(NSNumber *k in objById) { A3DPOFSub *s=objById[k]; if(s.parent==cur.intValue)[q addObject:@(s.sid)]; } }
        for(NSNumber *k in objById) { A3DPOFSub *s=objById[k]; if([ids containsObject:@(s.sid)])[m.subs addObject:s]; }
        if(m.subs.count>0) { if(errOut)*errOut=[NSString stringWithFormat:@"ok lod0 subs=%lu",(unsigned long)m.subs.count]; return m; }
    }
    int top=INT_MAX;
    for(NSNumber *k in objById) { A3DPOFSub *s=objById[k]; if(s.parent<0&&s.sid<top)top=s.sid; }
    for(NSNumber *k in objById) { A3DPOFSub *s=objById[k]; if(s.parent<0||s.parent==top)[m.subs addObject:s]; }
    if(m.subs.count==0) { if(errOut)*errOut=@"no drawable subobjects"; return nil; }
    if(errOut)*errOut=[NSString stringWithFormat:@"ok fallback subs=%lu",(unsigned long)m.subs.count];
    return m;
}

/* -------------------------------------------------------------------------
 * Texture loading (requires EGL context to be current)
 * ---------------------------------------------------------------------- */
static void ApplyTexParams3D(void) {
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT);
    glGenerateMipmap(GL_TEXTURE_2D);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR);
}
static GLuint CheckerTex3D(void) {
    unsigned char p[16]={255,255,255,255,20,20,20,255,20,20,20,255,255,255,255,255};
    GLuint t=0; glGenTextures(1,&t); glBindTexture(GL_TEXTURE_2D,t);
    glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA,2,2,0,GL_RGBA,GL_UNSIGNED_BYTE,p);
    ApplyTexParams3D(); return t;
}
static GLuint UploadRGBA(NSMutableData *rgba, NSInteger w, NSInteger h) {
    GLuint t=0; glGenTextures(1,&t); glBindTexture(GL_TEXTURE_2D,t);
    glPixelStorei(GL_UNPACK_ALIGNMENT,1);
    glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA,(GLsizei)w,(GLsizei)h,0,GL_RGBA,GL_UNSIGNED_BYTE,rgba.bytes);
    ApplyTexParams3D(); return t;
}
static void DecodeRGB565(uint16_t c, uint8_t rgba[4]) {
    uint8_t r=(c>>11)&31, g=(c>>5)&63, bb=c&31;
    rgba[0]=(r<<3)|(r>>2); rgba[1]=(g<<2)|(g>>4); rgba[2]=(bb<<3)|(bb>>2); rgba[3]=255;
}
static void StorePx(uint8_t *out,uint32_t w,uint32_t h,uint32_t x,uint32_t y,const uint8_t rgba[4]) {
    if(x>=w||y>=h) return;
    NSUInteger off=((NSUInteger)y*(NSUInteger)w+(NSUInteger)x)*4;
    out[off]=rgba[0]; out[off+1]=rgba[1]; out[off+2]=rgba[2]; out[off+3]=rgba[3];
}
static BOOL DecodeDXT1(const uint8_t *src,NSUInteger sl,uint32_t w,uint32_t h,NSMutableData **out) {
    uint32_t bx=(w+3)/4, by=(h+3)/4; NSUInteger need=(NSUInteger)bx*(NSUInteger)by*8;
    if(sl<need) return NO;
    *out=[NSMutableData dataWithLength:(NSUInteger)w*(NSUInteger)h*4];
    uint8_t *o=(uint8_t *)(*out).mutableBytes; NSUInteger p=0;
    for(uint32_t ry=0;ry<by;ry++) for(uint32_t rx=0;rx<bx;rx++) {
        uint16_t c0=U16(src+p),c1=U16(src+p+2); uint32_t bits=U32(src+p+4); p+=8;
        uint8_t col[4][4]; DecodeRGB565(c0,col[0]); DecodeRGB565(c1,col[1]);
        if(c0>c1) { for(int i=0;i<3;i++){col[2][i]=(2*col[0][i]+col[1][i])/3;col[3][i]=(col[0][i]+2*col[1][i])/3;}col[2][3]=col[3][3]=255; }
        else { for(int i=0;i<3;i++){col[2][i]=(col[0][i]+col[1][i])/2;col[3][i]=0;}col[2][3]=255;col[3][3]=0; }
        for(uint32_t py=0;py<4;py++) for(uint32_t px=0;px<4;px++) { uint32_t idx=bits&3; bits>>=2; StorePx(o,w,h,rx*4+px,ry*4+py,col[idx]); }
    }
    return YES;
}
static BOOL DecodeDXT5(const uint8_t *src,NSUInteger sl,uint32_t w,uint32_t h,NSMutableData **out) {
    uint32_t bx=(w+3)/4,by=(h+3)/4; NSUInteger need=(NSUInteger)bx*(NSUInteger)by*16;
    if(sl<need) return NO;
    *out=[NSMutableData dataWithLength:(NSUInteger)w*(NSUInteger)h*4];
    uint8_t *o=(uint8_t *)(*out).mutableBytes; NSUInteger p=0;
    for(uint32_t ry=0;ry<by;ry++) for(uint32_t rx=0;rx<bx;rx++) {
        uint8_t a0=src[p],a1=src[p+1]; uint64_t ab=0;
        for(int i=0;i<6;i++) ab|=((uint64_t)src[p+2+i])<<(8*i);
        uint16_t c0=U16(src+p+8),c1=U16(src+p+10); uint32_t bits=U32(src+p+12); p+=16;
        uint8_t atab[8]; atab[0]=a0; atab[1]=a1;
        if(a0>a1){for(int i=1;i<6;i++)atab[i+1]=(uint8_t)(((6-i)*a0+(i)*a1)/7);}
        else{for(int i=1;i<4;i++)atab[i+1]=(uint8_t)(((4-i)*a0+(i)*a1)/5);atab[6]=0;atab[7]=255;}
        uint8_t col[4][4]; DecodeRGB565(c0,col[0]); DecodeRGB565(c1,col[1]);
        for(int i=0;i<3;i++){col[2][i]=(2*col[0][i]+col[1][i])/3;col[3][i]=(col[0][i]+2*col[1][i])/3;} col[2][3]=col[3][3]=255;
        for(uint32_t py=0;py<4;py++) for(uint32_t px=0;px<4;px++) {
            uint8_t ai=(uint8_t)(ab&7); ab>>=3; uint32_t ci=bits&3; bits>>=2;
            uint8_t px4[4]={col[ci][0],col[ci][1],col[ci][2],atab[ai]};
            StorePx(o,w,h,rx*4+px,ry*4+py,px4);
        }
    }
    return YES;
}
static BOOL UploadDDS(NSString *p, GLuint *tex) {
    NSData *d=[NSData dataWithContentsOfFile:p]; if(!d||d.length<128) return NO;
    const uint8_t *b=d.bytes; if(memcmp(b,"DDS ",4)!=0) return NO;
    uint32_t w=U32(b+16),h=U32(b+12);
    if(w==0||h==0||w>16384||h>16384) return NO;
    char fcc[5]={0}; memcpy(fcc,b+84,4);
    NSMutableData *rgba=nil; BOOL ok=NO;
    if(!memcmp(fcc,"DXT1",4)) ok=DecodeDXT1(b+128,d.length-128,w,h,&rgba);
    else if(!memcmp(fcc,"DXT5",4)) ok=DecodeDXT5(b+128,d.length-128,w,h,&rgba);
    if(!ok||!rgba) return NO;
    *tex=UploadRGBA(rgba,(NSInteger)w,(NSInteger)h); return YES;
}
static NSString *CIPath(NSString *c) {
    if(!c.length) return nil;
    NSFileManager *fm=[NSFileManager defaultManager];
    if([fm fileExistsAtPath:c]) return c;
    NSString *dir=[c stringByDeletingLastPathComponent], *leaf=[c lastPathComponent];
    for(NSString *item in [fm contentsOfDirectoryAtPath:dir error:nil])
        if([item caseInsensitiveCompare:leaf]==NSOrderedSame) return [dir stringByAppendingPathComponent:item];
    return nil;
}
static GLuint LoadTex3D(NSString *p) {
    if(!p.length||![[NSFileManager defaultManager] fileExistsAtPath:p]) return CheckerTex3D();
    GLuint ddsTex=0;
    if([[p.pathExtension lowercaseString] isEqualToString:@"dds"]&&UploadDDS(p,&ddsTex)) return ddsTex;
    NSImage *img=[[NSImage alloc] initWithContentsOfFile:p];
    if(!img) return CheckerTex3D();
    NSBitmapImageRep *rep=nil;
    for(NSImageRep *r in [img representations]) if([r isKindOfClass:[NSBitmapImageRep class]]){rep=(NSBitmapImageRep*)r;break;}
    if(!rep) { NSData *tf=[img TIFFRepresentation]; if(tf) for(NSImageRep *r in [NSBitmapImageRep imageRepsWithData:tf]) if([r isKindOfClass:[NSBitmapImageRep class]]){rep=(NSBitmapImageRep*)r;break;} }
    if(!rep) return CheckerTex3D();
    NSInteger w=[rep pixelsWide], h=[rep pixelsHigh]; if(w<=0||h<=0) return CheckerTex3D();
    NSMutableData *rgba=[NSMutableData dataWithLength:(NSUInteger)w*(NSUInteger)h*4];
    unsigned char *out=(unsigned char*)rgba.mutableBytes;
    for(NSInteger y=0;y<h;y++) for(NSInteger x=0;x<w;x++) {
        NSColor *c=[[rep colorAtX:x y:y] colorUsingColorSpaceName:NSCalibratedRGBColorSpace]?:[NSColor magentaColor];
        NSUInteger off=((NSUInteger)y*(NSUInteger)w+(NSUInteger)x)*4;
        out[off+0]=(unsigned char)(fmaxf(0,fminf(1,[c redComponent]))*255);
        out[off+1]=(unsigned char)(fmaxf(0,fminf(1,[c greenComponent]))*255);
        out[off+2]=(unsigned char)(fmaxf(0,fminf(1,[c blueComponent]))*255);
        out[off+3]=(unsigned char)(fmaxf(0,fminf(1,[c alphaComponent]))*255);
    }
    return UploadRGBA(rgba,w,h);
}
static A3DEffAnim *LoadEffAnim(NSString *effPath) {
    NSString *raw=[NSString stringWithContentsOfFile:effPath encoding:NSUTF8StringEncoding error:nil];
    if(!raw) return nil;
    NSString *type=@"dds"; NSInteger fc=0; float fps=15.0f;
    for(NSString *line in [raw componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *l=[[[line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] lowercaseString] copy];
        if([l hasPrefix:@"$type:"]) type=[[l substringFromIndex:6] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        else if([l hasPrefix:@"$frames:"]) fc=[[l substringFromIndex:8] integerValue];
        else if([l hasPrefix:@"$fps:"]) fps=[[l substringFromIndex:5] floatValue];
    }
    if(fc<=0||fps<=0) return nil;
    NSString *base=[[effPath lastPathComponent] stringByDeletingPathExtension], *dir=[effPath stringByDeletingLastPathComponent];
    NSMutableArray *frames=[[NSMutableArray alloc] initWithCapacity:(NSUInteger)fc];
    for(NSInteger i=0;i<fc;i++) {
        NSString *name=[NSString stringWithFormat:@"%@_%04ld.%@",base,(long)i,type];
        NSString *fp=CIPath([dir stringByAppendingPathComponent:name]);
        [frames addObject:@(LoadTex3D(fp.length?fp:name))];
    }
    A3DEffAnim *a=[A3DEffAnim new]; a.frames=frames; a.fps=fps; return a;
}

/* -------------------------------------------------------------------------
 * GLSL ES 3.00 shaders
 * ---------------------------------------------------------------------- */
static const char *kMeshVert =
    "#version 300 es\n"
    "precision highp float;\n"
    "layout(location=0) in vec3 aPos;\n"
    "layout(location=1) in vec3 aNormal;\n"
    "layout(location=2) in vec2 aUV;\n"
    "uniform mat4 uModel,uView,uProj;\n"
    "out vec3 vViewPos,vViewNormal; out vec2 vUV;\n"
    "void main(){\n"
    "  vec4 vp=uView*uModel*vec4(aPos,1.0); vViewPos=vp.xyz;\n"
    "  vViewNormal=mat3(uView*uModel)*aNormal; vUV=aUV;\n"
    "  gl_Position=uProj*vp;}\n";
static const char *kMeshFrag =
    "#version 300 es\n"
    "precision highp float;\n"
    "uniform sampler2D uDiffuse,uNormal,uShine;\n"
    "uniform vec3 uLightDir; uniform int uHasNormal,uHasShine,uEmissive;\n"
    "in vec3 vViewPos,vViewNormal; in vec2 vUV; out vec4 fragColor;\n"
    "void main(){\n"
    "  vec4 base=texture(uDiffuse,vUV);\n"
    "  if(uEmissive!=0){fragColor=base;return;}\n"
    "  vec3 N=normalize(vViewNormal); if(dot(N,-vViewPos)<0.0)N=-N;\n"
    "  if(uHasNormal!=0){\n"
    "    vec3 dPdx=dFdx(vViewPos),dPdy=dFdy(vViewPos);\n"
    "    vec2 dUVdx=dFdx(vUV),dUVdy=dFdy(vUV);\n"
    "    float det=dUVdx.x*dUVdy.y-dUVdy.x*dUVdx.y;\n"
    "    if(abs(det)>1e-6){\n"
    "      vec3 T=normalize((dUVdy.y*dPdx-dUVdx.y*dPdy)/det);\n"
    "      T=normalize(T-dot(T,N)*N); vec3 B=cross(N,T);\n"
    "      vec4 ntex=texture(uNormal,vUV);\n"
    "      vec3 ns; ns.x=ntex.g*2.0-1.0; ns.y=ntex.a*2.0-1.0;\n"
    "      ns.z=sqrt(max(0.0,1.0-ns.x*ns.x-ns.y*ns.y));\n"
    "      N=normalize(mat3(T,B,N)*ns);}}\n"
    "  float NdL=max(dot(N,uLightDir),0.0);\n"
    "  vec3 V=normalize(-vViewPos),H=normalize(uLightDir+V);\n"
    "  float spec=pow(max(dot(N,H),0.0),64.0);\n"
    "  if(uHasShine!=0) spec*=texture(uShine,vUV).r*10.0; else spec=0.0;\n"
    "  vec3 lit=base.rgb*(0.2+NdL)+vec3(spec);\n"
    "  fragColor=vec4(lit,base.a);}\n";
static const char *kFlatVert =
    "#version 300 es\n"
    "precision highp float;\n"
    "layout(location=0) in vec3 aPos; layout(location=1) in vec4 aColor;\n"
    "uniform mat4 uMVP; uniform float uPointSize; out vec4 vColor;\n"
    "void main(){vColor=aColor; gl_Position=uMVP*vec4(aPos,1.0); gl_PointSize=uPointSize;}\n";
static const char *kFlatFrag =
    "#version 300 es\n"
    "precision highp float;\n"
    "in vec4 vColor; uniform vec4 uColorMul; uniform float uCircleClip; out vec4 fragColor;\n"
    "void main(){\n"
    "  if(uCircleClip>0.5){vec2 c=gl_PointCoord-vec2(0.5); if(dot(c,c)>0.25)discard;}\n"
    "  fragColor=vColor*uColorMul;}\n";

static GLuint CompileShader3D(GLenum type, const char *src) {
    GLuint s=glCreateShader(type);
    glShaderSource(s,1,&src,NULL); glCompileShader(s);
    GLint ok=0; glGetShaderiv(s,GL_COMPILE_STATUS,&ok);
    if(!ok) { char log[2048]={0}; glGetShaderInfoLog(s,sizeof(log)-1,NULL,log); wlr_log(WLR_ERROR,"3dbg shader: %s",log); glDeleteShader(s); return 0; }
    return s;
}
static GLuint BuildProg3D(const char *vs, const char *fs) {
    GLuint v=CompileShader3D(GL_VERTEX_SHADER,vs), f=CompileShader3D(GL_FRAGMENT_SHADER,fs);
    if(!v||!f){glDeleteShader(v);glDeleteShader(f);return 0;}
    GLuint p=glCreateProgram(); glAttachShader(p,v); glAttachShader(p,f); glLinkProgram(p);
    GLint ok=0; glGetProgramiv(p,GL_LINK_STATUS,&ok);
    glDeleteShader(v); glDeleteShader(f);
    if(!ok){char log[2048]={0};glGetProgramInfoLog(p,sizeof(log)-1,NULL,log);wlr_log(WLR_ERROR,"3dbg link: %s",log);glDeleteProgram(p);return 0;}
    return p;
}
static void BuildFlatVAO3D(const float *vd, size_t bytes, GLuint *vao, GLuint *vbo) {
    glGenVertexArrays(1,vao); glGenBuffers(1,vbo);
    glBindVertexArray(*vao); glBindBuffer(GL_ARRAY_BUFFER,*vbo);
    glBufferData(GL_ARRAY_BUFFER,(GLsizeiptr)bytes,vd,GL_STATIC_DRAW);
    glVertexAttribPointer(0,3,GL_FLOAT,GL_FALSE,7*sizeof(float),(void*)0);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(1,4,GL_FLOAT,GL_FALSE,7*sizeof(float),(void*)(3*sizeof(float)));
    glEnableVertexAttribArray(1);
    glBindBuffer(GL_ARRAY_BUFFER,0); glBindVertexArray(0);
}

/* -------------------------------------------------------------------------
 * wlr_buffer backed by a Cairo image surface (same as AmbrosiaBackground.m)
 * ---------------------------------------------------------------------- */
struct a3d_bg_buffer { struct wlr_buffer base; cairo_surface_t *surface; };
static void a3d_buf_destroy(struct wlr_buffer *buf) {
    struct a3d_bg_buffer *b=wl_container_of(buf,b,base);
    cairo_surface_destroy(b->surface); free(b);
}
static bool a3d_buf_begin_ptr(struct wlr_buffer *buf,uint32_t flags,void **data,uint32_t *fmt,size_t *stride) {
    struct a3d_bg_buffer *b=wl_container_of(buf,b,base);
    cairo_surface_flush(b->surface);
    *data=cairo_image_surface_get_data(b->surface);
    *fmt=DRM_FORMAT_ARGB8888;
    *stride=(size_t)cairo_image_surface_get_stride(b->surface);
    return true;
}
static void a3d_buf_end_ptr(struct wlr_buffer *buf) {
    struct a3d_bg_buffer *b=wl_container_of(buf,b,base);
    cairo_surface_mark_dirty(b->surface);
}
static const struct wlr_buffer_impl a3d_buf_impl = {
    .destroy=a3d_buf_destroy,.begin_data_ptr_access=a3d_buf_begin_ptr,.end_data_ptr_access=a3d_buf_end_ptr
};
static struct a3d_bg_buffer *a3d_buf_create(cairo_surface_t *surf) {
    struct a3d_bg_buffer *b=calloc(1,sizeof(*b)); if(!b){cairo_surface_destroy(surf);return NULL;}
    b->surface=surf;
    wlr_buffer_init(&b->base,&a3d_buf_impl,cairo_image_surface_get_width(surf),cairo_image_surface_get_height(surf));
    return b;
}

/* -------------------------------------------------------------------------
 * Per-output record
 * ---------------------------------------------------------------------- */
@interface _A3DOutput : NSObject
@property(nonatomic) struct wlr_output       *output;
@property(nonatomic) struct wlr_scene_buffer *node;
@property(nonatomic) GLuint                   fbo;
@property(nonatomic) GLuint                   colorTex;
@property(nonatomic) GLuint                   depthRbo;
@property(nonatomic) int                      w;
@property(nonatomic) int                      h;
@end
@implementation _A3DOutput @end

/* -------------------------------------------------------------------------
 * Animation timer trampoline
 * ---------------------------------------------------------------------- */
struct a3d_timer_ctx { struct wl_event_source *source; void *bg; };
static int a3d_timer_cb(void *data);   /* forward */

/* -------------------------------------------------------------------------
 * Ambrosia3DBackground
 * ---------------------------------------------------------------------- */
@implementation Ambrosia3DBackground {
    struct wl_event_loop     *_loop;
    struct wlr_scene_tree    *_bgTree;
    struct wlr_output_layout *_layout;

    NSMutableArray<_A3DOutput *> *_outputs;

    /* EGL offscreen context */
    EGLDisplay  _eglDpy;
    EGLContext  _eglCtx;
    EGLSurface  _eglPbuf;

    /* GL resources */
    BOOL    _glReady;
    GLuint  _shader;          /* mesh program */
    GLint   _uModel, _uView, _uProj;
    GLint   _uDiffuse, _uNormal, _uShine;
    GLint   _uHasNormal, _uHasShine, _uLightDir, _uEmissive;
    GLuint  _flatShader;      /* flat program */
    GLint   _uMVP, _uPointSize, _uColorMul, _uCircleClip;

    GLuint  _starsVAO, _starsVBO;
    GLuint  _axesVAO,  _axesVBO;
    GLuint  _cubeVAO,  _cubeVBO;
    NSMutableArray *_loopVAOs;
    NSMutableArray *_loopVBOs;

    /* Scene state */
    A3DSceneDef         *_scene;
    NSMutableDictionary *_meshCache;
    NSMutableDictionary *_texCache;
    NSMutableDictionary *_matCache;
    GLuint               _skyboxTex;
    BOOL                 _skyboxLoaded;
    NSMutableData       *_starPositions;
    Mat4                 _proj;
    Mat4                 _view;

    /* Animation timing */
    NSTimeInterval       _lastTick;
    float                _elapsed;

    /* Rotation timer */
    struct a3d_timer_ctx *_timer;
}

- (instancetype)initWithEventLoop:(struct wl_event_loop *)loop
                        sceneTree:(struct wlr_scene_tree *)bgTree
                     outputLayout:(struct wlr_output_layout *)layout
                    sceneFilePath:(NSString *)scenePath
{
    self = [super init];
    if (!self) return nil;

    _loop    = loop;
    _bgTree  = bgTree;
    _layout  = layout;
    _outputs = [NSMutableArray array];
    _eglDpy  = EGL_NO_DISPLAY;
    _eglCtx  = EGL_NO_CONTEXT;
    _eglPbuf = EGL_NO_SURFACE;

    /* Load scene */
    NSError *err = nil;
    _scene = ParseScene(scenePath, &err);
    if (!_scene) {
        wlr_log(WLR_ERROR, "3dbg: scene load failed: %s",
                err ? [[err description] UTF8String] : "(null)");
        return self;
    }
    wlr_log(WLR_INFO, "3dbg: scene '%s' loaded, %lu model(s)",
            [scenePath UTF8String], (unsigned long)_scene.models.count);

    _meshCache = [NSMutableDictionary dictionary];
    _texCache  = [NSMutableDictionary dictionary];
    _matCache  = [NSMutableDictionary dictionary];

    /* Seed 1500 random stars */
    _starPositions = [NSMutableData dataWithLength:sizeof(Vec3)*1500];
    Vec3 *q = (Vec3 *)_starPositions.mutableBytes;
    for (int i = 0; i < 1500; i++) {
        q[i] = (Vec3){
            ((float)arc4random()/(float)UINT32_MAX - 0.5f) * 40000.0f,
            ((float)arc4random()/(float)UINT32_MAX - 0.5f) * 40000.0f,
            -((float)arc4random()/(float)UINT32_MAX) * 40000.0f
        };
    }

    _lastTick = [NSDate timeIntervalSinceReferenceDate];

    if (![self _setupEGL]) {
        wlr_log(WLR_ERROR, "3dbg: EGL setup failed");
        return self;
    }

    [self _startTimer];
    return self;
}

- (void)dealloc { [self stop]; }

/* -------------------------------------------------------------------------
 * EGL setup
 * ---------------------------------------------------------------------- */
- (BOOL)_setupEGL
{
    _eglDpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (_eglDpy == EGL_NO_DISPLAY) return NO;

    if (!eglInitialize(_eglDpy, NULL, NULL)) return NO;
    if (!eglBindAPI(EGL_OPENGL_ES_API)) return NO;

    EGLint cfgAttribs[] = {
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT_KHR,
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_NONE
    };
    EGLConfig cfg; EGLint nCfg = 0;
    if (!eglChooseConfig(_eglDpy, cfgAttribs, &cfg, 1, &nCfg) || nCfg < 1) return NO;

    EGLint ctxAttribs[] = {
        EGL_CONTEXT_MAJOR_VERSION, 3,
        EGL_CONTEXT_MINOR_VERSION, 0,
        EGL_NONE
    };
    _eglCtx = eglCreateContext(_eglDpy, cfg, EGL_NO_CONTEXT, ctxAttribs);
    if (_eglCtx == EGL_NO_CONTEXT) return NO;

    EGLint pbufAttribs[] = { EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE };
    _eglPbuf = eglCreatePbufferSurface(_eglDpy, cfg, pbufAttribs);
    if (_eglPbuf == EGL_NO_SURFACE) return NO;

    if (!eglMakeCurrent(_eglDpy, _eglPbuf, _eglPbuf, _eglCtx)) return NO;

    eglMakeCurrent(_eglDpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    return YES;
}

/* -------------------------------------------------------------------------
 * GL resource initialisation (called once, with our EGL context current)
 * ---------------------------------------------------------------------- */
- (void)_initGL
{
    if (_glReady) return;
    _glReady = YES;

    glEnable(GL_DEPTH_TEST); glDepthFunc(GL_LEQUAL);
    glEnable(GL_CULL_FACE); glCullFace(GL_BACK); glFrontFace(GL_CCW);
    glClearDepthf(1.0f);

    _shader = BuildProg3D(kMeshVert, kMeshFrag);
    if (_shader) {
        _uModel=glGetUniformLocation(_shader,"uModel"); _uView=glGetUniformLocation(_shader,"uView");
        _uProj=glGetUniformLocation(_shader,"uProj");   _uDiffuse=glGetUniformLocation(_shader,"uDiffuse");
        _uNormal=glGetUniformLocation(_shader,"uNormal");_uShine=glGetUniformLocation(_shader,"uShine");
        _uHasNormal=glGetUniformLocation(_shader,"uHasNormal"); _uHasShine=glGetUniformLocation(_shader,"uHasShine");
        _uLightDir=glGetUniformLocation(_shader,"uLightDir");   _uEmissive=glGetUniformLocation(_shader,"uEmissive");
        glUseProgram(_shader);
        glUniform1i(_uDiffuse,0); glUniform1i(_uNormal,1); glUniform1i(_uShine,2); glUniform1i(_uEmissive,0);
        glUseProgram(0);
    }
    _flatShader = BuildProg3D(kFlatVert, kFlatFrag);
    if (_flatShader) {
        _uMVP=glGetUniformLocation(_flatShader,"uMVP"); _uPointSize=glGetUniformLocation(_flatShader,"uPointSize");
        _uColorMul=glGetUniformLocation(_flatShader,"uColorMul"); _uCircleClip=glGetUniformLocation(_flatShader,"uCircleClip");
    }

    /* Stars VAO */
    {
        Vec3 *st=(Vec3*)_starPositions.bytes; float sv[1500*7];
        for(int i=0;i<1500;i++){sv[i*7]=st[i].x;sv[i*7+1]=st[i].y;sv[i*7+2]=st[i].z;sv[i*7+3]=sv[i*7+4]=sv[i*7+5]=sv[i*7+6]=1.0f;}
        BuildFlatVAO3D(sv,sizeof(sv),&_starsVAO,&_starsVBO);
    }
    /* Axes VAO */
    {
        float ax[]={0,0,0,1,0,0,1, 25,0,0,1,0,0,1, 0,0,0,0,1,0,1, 0,25,0,0,1,0,1, 0,0,0,0,0,1,1, 0,0,25,0,0,1,1};
        BuildFlatVAO3D(ax,sizeof(ax),&_axesVAO,&_axesVBO);
    }
    /* Placeholder cube VAO */
    {
        static const float pos[36*3]={-1,-1,-1,-1,1,-1,1,1,-1,-1,-1,-1,1,1,-1,1,-1,-1,-1,-1,1,1,-1,1,1,1,1,-1,-1,1,1,1,1,-1,1,1,-1,-1,-1,-1,-1,1,-1,1,1,-1,-1,-1,-1,1,1,-1,1,-1,1,-1,-1,1,1,1,1,-1,1,1,-1,-1,1,1,1,1,1,-1,-1,-1,-1,1,-1,1,1,-1,-1,-1,-1,-1,-1,-1,1,1,-1,1,-1,1,-1,-1,1,1,1,1,1,-1,1,-1,1,1,-1,1,1};
        float cv[36*7]; for(int i=0;i<36;i++){cv[i*7]=pos[i*3];cv[i*7+1]=pos[i*3+1];cv[i*7+2]=pos[i*3+2];cv[i*7+3]=cv[i*7+4]=cv[i*7+5]=cv[i*7+6]=1.0f;}
        BuildFlatVAO3D(cv,sizeof(cv),&_cubeVAO,&_cubeVBO);
    }
    /* Orbit loop VAOs */
    _loopVAOs = [NSMutableArray array]; _loopVBOs = [NSMutableArray array];
    for (A3DSceneModel *m in _scene.models) {
        if (!m.hasOvalPath||m.ovalRadius<=0) { [_loopVAOs addObject:@(0u)]; [_loopVBOs addObject:@(0u)]; continue; }
        float lv[64*7];
        for(int i=0;i<64;i++){
            float a=DegToRad3D(360.0f*(float)i/64.0f);
            Vec3 pt=V3RotXYZ((Vec3){cosf(a)*m.ovalRadius,0.0f,sinf(a)*m.ovalRadius},m.ovalPlaneRot);
            lv[i*7]=m.position.x+pt.x; lv[i*7+1]=m.position.y+pt.y; lv[i*7+2]=m.position.z+pt.z;
            lv[i*7+3]=1.0f; lv[i*7+4]=0.2f; lv[i*7+5]=0.2f; lv[i*7+6]=1.0f;
        }
        GLuint lVAO=0,lVBO=0; BuildFlatVAO3D(lv,sizeof(lv),&lVAO,&lVBO);
        [_loopVAOs addObject:@(lVAO)]; [_loopVBOs addObject:@(lVBO)];
    }
}

/* -------------------------------------------------------------------------
 * Per-output FBO management
 * ---------------------------------------------------------------------- */
- (void)_createFBOForOutput:(_A3DOutput *)rec
{
    int w = rec.output->width, h = rec.output->height;
    if (w <= 0 || h <= 0) return;
    rec.w = w; rec.h = h;

    GLuint fbo=0, ct=0, dr=0;
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);

    glGenTextures(1, &ct);
    glBindTexture(GL_TEXTURE_2D, ct);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, ct, 0);

    glGenRenderbuffers(1, &dr);
    glBindRenderbuffer(GL_RENDERBUFFER, dr);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, w, h);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, dr);

    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    rec.fbo = fbo; rec.colorTex = ct; rec.depthRbo = dr;

    /* Set up projection for this output's aspect ratio */
    float asp = (float)w / (float)h;
    float nn = VIEW_NEAR_PLANE, ff = VIEW_FAR_PLANE;
    float top = tanf(DegToRad3D(VIEW_FOV_Y_DEG * 0.5f)) * nn;
    float right = top * asp;
    _proj = Mat4Frustum(-right, right, -top, top, nn, ff);
}

- (void)_destroyFBOForOutput:(_A3DOutput *)rec
{
    GLuint tmp;
    if (rec.fbo)      { tmp = rec.fbo;      glDeleteFramebuffers(1,   &tmp); rec.fbo = 0; }
    if (rec.colorTex) { tmp = rec.colorTex; glDeleteTextures(1,       &tmp); rec.colorTex = 0; }
    if (rec.depthRbo) { tmp = rec.depthRbo; glDeleteRenderbuffers(1,  &tmp); rec.depthRbo = 0; }
}

/* -------------------------------------------------------------------------
 * Texture/material helpers (require GL context to be current)
 * ---------------------------------------------------------------------- */
- (NSString *)_texFilePath:(NSString *)tn
{
    NSString *key = [(tn ?: @"") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!key.length) return nil;
    NSString *base = [_scene.textureRoot stringByAppendingPathComponent:key];
    NSString *ci = CIPath(base);
    if (ci.length) return ci;
    if ([[base pathExtension] length] == 0) {
        for (NSString *e in @[@"eff",@"dds",@"png",@"pcx",@"jpg",@"jpeg",@"tga",@"bmp"]) {
            NSString *ci2 = CIPath([base stringByAppendingPathExtension:e]);
            if (ci2.length) return ci2;
        }
    } else {
        NSString *stem = [base stringByDeletingPathExtension];
        for (NSString *e in @[@"eff",@"dds",@"png",@"pcx",@"jpg",@"jpeg",@"tga",@"bmp"]) {
            NSString *ci2 = CIPath([stem stringByAppendingPathExtension:e]);
            if (ci2.length) return ci2;
        }
    }
    return nil;
}

- (GLuint)_texForName:(NSString *)tn
{
    NSString *key = [(tn ?: @"") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSNumber *ct = _texCache[key]; if (ct) return ct.unsignedIntValue;
    NSString *fp = [self _texFilePath:key];
    GLuint tx = LoadTex3D(fp); if (tx) _texCache[key] = @(tx);
    return tx;
}

- (A3DTexMat *)_matForName:(NSString *)tn
{
    NSString *key = [(tn ?: @"") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!key.length) key = @"<empty>";
    A3DTexMat *m = _matCache[key]; if (m) return m;
    m = [A3DTexMat new]; m.baseName = key;
    NSString *stem = [[key pathExtension] length] ? [key stringByDeletingPathExtension] : key;
    m.diffusePath = [self _texFilePath:key];
    m.glowPath    = [self _texFilePath:[stem stringByAppendingString:@"-glow"]];
    m.normalPath  = [self _texFilePath:[stem stringByAppendingString:@"-normal"]];
    m.shinePath   = [self _texFilePath:[stem stringByAppendingString:@"-shine"]];
    if ([m.diffusePath.pathExtension.lowercaseString isEqualToString:@"eff"]) m.diffuseAnim=LoadEffAnim(m.diffusePath); else m.diffuse=LoadTex3D(m.diffusePath);
    if (m.glowPath.length)   { if ([m.glowPath.pathExtension.lowercaseString   isEqualToString:@"eff"]) m.glowAnim=LoadEffAnim(m.glowPath);     else m.glow=LoadTex3D(m.glowPath); }
    if (m.normalPath.length) { if ([m.normalPath.pathExtension.lowercaseString isEqualToString:@"eff"]) m.normalAnim=LoadEffAnim(m.normalPath); else m.normal=LoadTex3D(m.normalPath); }
    if (m.shinePath.length)  { if ([m.shinePath.pathExtension.lowercaseString  isEqualToString:@"eff"]) m.shineAnim=LoadEffAnim(m.shinePath);   else m.shine=LoadTex3D(m.shinePath); }
    if (m.diffuse||m.diffuseAnim) _matCache[key]=m;
    return m;
}

/* -------------------------------------------------------------------------
 * VBO building for a POF subobject
 * ---------------------------------------------------------------------- */
- (void)_buildVBOs:(A3DPOFSub *)s mesh:(A3DPOFMesh *)pm
{
    s.vbosBuilt = YES;
    const A3DPOFTri *tri = (const A3DPOFTri *)s.tris.bytes;
    NSUInteger tc = s.tris.length / sizeof(A3DPOFTri);
    if (tc == 0) { s.vboBatches = [NSMutableData data]; return; }
    /* Face normals */
    NSMutableData *fnD = [NSMutableData dataWithLength:tc*3*sizeof(float)];
    float *fn = fnD.mutableBytes;
    for (NSUInteger t=0;t<tc;t++) {
        float ex=tri[t].p[1].x-tri[t].p[0].x,ey=tri[t].p[1].y-tri[t].p[0].y,ez=tri[t].p[1].z-tri[t].p[0].z;
        float fx=tri[t].p[2].x-tri[t].p[0].x,fy=tri[t].p[2].y-tri[t].p[0].y,fz=tri[t].p[2].z-tri[t].p[0].z;
        float nx=ey*fz-ez*fy,ny=ez*fx-ex*fz,nz=ex*fy-ey*fx;
        float nl=sqrtf(nx*nx+ny*ny+nz*nz); if(nl>1e-10f){nx/=nl;ny/=nl;nz/=nl;}
        fn[t*3]=nx;fn[t*3+1]=ny;fn[t*3+2]=nz;
    }
    /* Position → triangle index map for smooth normals */
    NSMutableDictionary *p2t=[NSMutableDictionary dictionary];
    for(NSUInteger t=0;t<tc;t++) for(int k=0;k<3;k++){
        float pos3[3]={tri[t].p[k].x,tri[t].p[k].y,tri[t].p[k].z};
        NSData *key=[NSData dataWithBytes:pos3 length:12];
        NSMutableArray *list=p2t[key]; if(!list){list=[NSMutableArray array];p2t[key]=list;}
        [list addObject:@(t)];
    }
    const float cosT=cosf(80.0f*(float)M_PI/180.0f);
    NSMutableData *snD=[NSMutableData dataWithLength:tc*3*3*sizeof(float)];
    float *sn=snD.mutableBytes;
    for(NSUInteger t=0;t<tc;t++){
        const float *nf=fn+t*3;
        for(int k=0;k<3;k++){
            float pos3[3]={tri[t].p[k].x,tri[t].p[k].y,tri[t].p[k].z};
            NSData *key=[NSData dataWithBytes:pos3 length:12];
            float ax=nf[0],ay=nf[1],az=nf[2];
            for(NSNumber *tn in (NSArray*)p2t[key]){
                NSUInteger t2=tn.unsignedIntegerValue; if(t2==t)continue;
                const float *nf2=fn+t2*3;
                if(nf[0]*nf2[0]+nf[1]*nf2[1]+nf[2]*nf2[2]>=cosT){ax+=nf2[0];ay+=nf2[1];az+=nf2[2];}
            }
            float nl=sqrtf(ax*ax+ay*ay+az*az); if(nl>1e-10f){ax/=nl;ay/=nl;az/=nl;}
            NSUInteger vi=(t*3+k)*3; sn[vi]=ax;sn[vi+1]=ay;sn[vi+2]=az;
        }
    }
    /* Group by texture and upload */
    NSMutableArray *order=[NSMutableArray array]; NSMutableSet *seen=[NSMutableSet set];
    for(NSUInteger t=0;t<tc;t++){NSNumber *kk=@(tri[t].texIndex);if(![seen containsObject:kk]){[seen addObject:kk];[order addObject:kk];}}
    NSMutableData *batches=[NSMutableData data];
    for(NSNumber *texKey in order){
        int texIdx=texKey.intValue; NSMutableData *verts=[NSMutableData data];
        for(NSUInteger t=0;t<tc;t++){
            if(tri[t].texIndex!=texIdx)continue;
            for(int k=0;k<3;k++){
                NSUInteger vi=(t*3+k)*3;
                float v[8]={tri[t].p[k].x,tri[t].p[k].y,tri[t].p[k].z,sn[vi],sn[vi+1],sn[vi+2],tri[t].uv[k][0],tri[t].uv[k][1]};
                [verts appendBytes:v length:sizeof(v)];
            }
        }
        const GLsizei stride=8*sizeof(float);
        GLuint vao=0,vbo=0;
        glGenVertexArrays(1,&vao); glGenBuffers(1,&vbo);
        glBindVertexArray(vao); glBindBuffer(GL_ARRAY_BUFFER,vbo);
        glBufferData(GL_ARRAY_BUFFER,(GLsizeiptr)verts.length,verts.bytes,GL_STATIC_DRAW);
        glVertexAttribPointer(0,3,GL_FLOAT,GL_FALSE,stride,(void*)0);           glEnableVertexAttribArray(0);
        glVertexAttribPointer(1,3,GL_FLOAT,GL_FALSE,stride,(void*)(12));        glEnableVertexAttribArray(1);
        glVertexAttribPointer(2,2,GL_FLOAT,GL_FALSE,stride,(void*)(24));        glEnableVertexAttribArray(2);
        glBindBuffer(GL_ARRAY_BUFFER,0); glBindVertexArray(0);
        A3DVBOBatch b; b.vao=vao; b.vbo=vbo; b.count=(GLsizei)(verts.length/(NSUInteger)stride); b.texIndex=texIdx;
        [batches appendBytes:&b length:sizeof(b)];
    }
    s.vboBatches = batches;
}

/* -------------------------------------------------------------------------
 * Draw a POF subobject and its children recursively
 * ---------------------------------------------------------------------- */
- (void)_drawSub:(A3DPOFSub *)s mesh:(A3DPOFMesh *)pm children:(NSDictionary *)ch
         elapsed:(float)elapsed reversed:(NSSet *)rev modelMat:(Mat4)modelMat
{
    if ([s.name rangeOfString:@"debris"  options:NSCaseInsensitiveSearch].location!=NSNotFound) return;
    if ([s.name rangeOfString:@"destroy" options:NSCaseInsensitiveSearch].location!=NSNotFound) return;

    Mat4 subMat = Mat4Mul(modelMat, Mat4Translate(s.offset.x, s.offset.y, s.offset.z));
    if (s.rotates) {
        BOOL rv = rev && [rev containsObject:@(s.sid)];
        float angle = (rv?-1.0f:1.0f) * elapsed * (360.0f/s.spin);
        Mat4 rot;
        switch(s.movementAxis){ case 0:rot=Mat4RotateX(angle);break; case 1:rot=Mat4RotateZ(angle);break; case 2:rot=Mat4RotateY(angle);break; default:rot=Mat4RotateY(angle);break; }
        subMat = Mat4Mul(subMat, rot);
    }
    if (!s.vbosBuilt) [self _buildVBOs:s mesh:pm];
    NSUInteger bc = s.vboBatches.length / sizeof(A3DVBOBatch);
    if (bc > 0) {
        const A3DVBOBatch *batches=(const A3DVBOBatch*)s.vboBatches.bytes;
        glUseProgram(_shader);
        glUniformMatrix4fv(_uModel, 1, GL_FALSE, subMat.m);
        for (NSUInteger b=0;b<bc;b++) {
            const A3DVBOBatch *batch=&batches[b];
            NSString *tn = s.tex ?: @"";
            if (batch->texIndex>=0&&batch->texIndex<(int)pm.textures.count) tn=pm.textures[(NSUInteger)batch->texIndex];
            A3DTexMat *mat = [self _matForName:tn];
            GLuint dTex = mat.diffuseAnim ? [mat.diffuseAnim frameAtTime:elapsed] : mat.diffuse;
            GLuint nTex = mat.normalAnim  ? [mat.normalAnim  frameAtTime:elapsed] : (mat.normal ? mat.normal : dTex);
            GLuint sTex = mat.shineAnim   ? [mat.shineAnim   frameAtTime:elapsed] : (mat.shine  ? mat.shine  : dTex);
            GLuint gTex = mat.glowAnim    ? [mat.glowAnim    frameAtTime:elapsed] : mat.glow;
            BOOL hasN = mat.normalAnim||mat.normal; BOOL hasS = mat.shineAnim||mat.shine;
            glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, dTex);
            glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, nTex);
            glActiveTexture(GL_TEXTURE2); glBindTexture(GL_TEXTURE_2D, sTex);
            glActiveTexture(GL_TEXTURE0);
            glUniform1i(_uHasNormal,(int)hasN); glUniform1i(_uHasShine,(int)hasS);
            glBindVertexArray(batch->vao); glDrawArrays(GL_TRIANGLES, 0, batch->count);
            if (gTex) {
                glEnable(GL_BLEND); glBlendFunc(GL_SRC_ALPHA,GL_ONE); glDepthMask(GL_FALSE);
                glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, gTex);
                glUniform1i(_uEmissive,1); glDrawArrays(GL_TRIANGLES,0,batch->count);
                glUniform1i(_uEmissive,0); glDepthMask(GL_TRUE); glDisable(GL_BLEND);
            }
        }
        glBindVertexArray(0); glUseProgram(0);
    } else {
        Mat4 mvp=Mat4Mul(_proj,Mat4Mul(_view,subMat));
        glUseProgram(_flatShader); glUniformMatrix4fv(_uMVP,1,GL_FALSE,mvp.m);
        glUniform1f(_uPointSize,1.0f); glUniform4f(_uColorMul,1,0,1,1);
        glDisable(GL_CULL_FACE); glBindVertexArray(_cubeVAO); glDrawArrays(GL_TRIANGLES,0,36);
        glBindVertexArray(0); glEnable(GL_CULL_FACE); glUseProgram(0);
    }
    NSArray *kids = ch[@(s.sid)];
    for (A3DPOFSub *child in kids)
        [self _drawSub:child mesh:pm children:ch elapsed:elapsed reversed:rev modelMat:subMat];
}

/* -------------------------------------------------------------------------
 * Render one frame to the given output's FBO and push to wlr_scene_buffer
 * ---------------------------------------------------------------------- */
- (void)_renderToOutput:(_A3DOutput *)rec
{
    if (!rec.fbo || rec.w <= 0 || rec.h <= 0) return;

    glBindFramebuffer(GL_FRAMEBUFFER, rec.fbo);
    glViewport(0, 0, rec.w, rec.h);

    /* Recompute projection for this output */
    float asp=(float)rec.w/(float)rec.h, nn=VIEW_NEAR_PLANE, ff=VIEW_FAR_PLANE;
    float top=tanf(DegToRad3D(VIEW_FOV_Y_DEG*0.5f))*nn, right=top*asp;
    _proj=Mat4Frustum(-right,right,-top,top,nn,ff);

    glClearColor(0.01f,0.01f,0.03f,1.0f);
    glClear(GL_COLOR_BUFFER_BIT|GL_DEPTH_BUFFER_BIT);

    _view=Mat4Translate(-_scene.cameraPosition.x,-_scene.cameraPosition.y,-_scene.cameraPosition.z);
    Mat4 flatMVP=Mat4Mul(_proj,_view);

    /* Skybox (load once) */
    if (!_skyboxLoaded) {
        _skyboxLoaded=YES;
        if (_scene.skyboxName.length) {
            NSString *base=[_scene.textureRoot stringByAppendingPathComponent:_scene.skyboxName];
            for (NSString *ext in @[@"png",@"dds",@"jpg",@"jpeg"]) {
                NSString *ci=CIPath([base stringByAppendingPathExtension:ext]);
                if (ci.length){_skyboxTex=LoadTex3D(ci);break;}
            }
            if(!_skyboxTex&&[[NSFileManager defaultManager] fileExistsAtPath:base]) _skyboxTex=LoadTex3D(base);
        }
    }

    /* Stars */
    if (!_skyboxTex) {
        glDisable(GL_DEPTH_TEST); glEnable(GL_BLEND); glBlendFunc(GL_SRC_ALPHA,GL_ONE_MINUS_SRC_ALPHA);
        glUseProgram(_flatShader); glUniformMatrix4fv(_uMVP,1,GL_FALSE,flatMVP.m);
        glUniform4f(_uColorMul,1,1,1,1); glUniform1f(_uCircleClip,1.0f);
        glBindVertexArray(_starsVAO);
        for(int pass=0;pass<3;pass++){glUniform1f(_uPointSize,(float)(pass+1)*2.0f);glDrawArrays(GL_POINTS,pass*500,500);}
        glBindVertexArray(0); glUniform1f(_uCircleClip,0.0f); glUseProgram(0);
        glDisable(GL_BLEND); glEnable(GL_DEPTH_TEST);
    }

    /* Orbit loops */
    if (_scene.showLoops && _loopVAOs.count) {
        glDisable(GL_DEPTH_TEST);
        glUseProgram(_flatShader); glUniformMatrix4fv(_uMVP,1,GL_FALSE,flatMVP.m);
        glUniform1f(_uPointSize,1.0f); glUniform4f(_uColorMul,1,1,1,1);
        for(NSUInteger mi=0;mi<_scene.models.count&&mi<_loopVAOs.count;mi++){
            GLuint lv=(GLuint)[[_loopVAOs objectAtIndex:mi] unsignedIntValue];
            if(lv){glBindVertexArray(lv);glDrawArrays(GL_LINE_LOOP,0,64);}
        }
        glBindVertexArray(0); glUseProgram(0); glEnable(GL_DEPTH_TEST);
    }

    /* Per-frame mesh shader constants */
    if (_shader) {
        Vec3 sd=_scene.sunDir;
        float ldv[3]={_view.m[0]*sd.x+_view.m[4]*sd.y+_view.m[8]*sd.z,
                      _view.m[1]*sd.x+_view.m[5]*sd.y+_view.m[9]*sd.z,
                      _view.m[2]*sd.x+_view.m[6]*sd.y+_view.m[10]*sd.z};
        float len=sqrtf(ldv[0]*ldv[0]+ldv[1]*ldv[1]+ldv[2]*ldv[2]);
        if(len>1e-6f){ldv[0]/=len;ldv[1]/=len;ldv[2]/=len;}
        glUseProgram(_shader);
        glUniformMatrix4fv(_uView,1,GL_FALSE,_view.m);
        glUniformMatrix4fv(_uProj,1,GL_FALSE,_proj.m);
        glUniform3fv(_uLightDir,1,ldv);
        glUseProgram(0);
    }

    /* Models */
    for (A3DSceneModel *m in _scene.models) {
        Vec3 p=m.position; Mat4 pathMat4=Mat4Identity(); BOOL usePath=NO;
        if (m.hasOvalPath&&m.ovalRadius>0) {
            float a=DegToRad3D(m.ovalAngleOffset+_elapsed*m.ovalSpeedDegPerSec);
            Vec3 lo,lt;
            if(m.ovalRev){lo=(Vec3){cosf(a)*m.ovalRadius,0,-sinf(a)*m.ovalRadius};lt=(Vec3){-sinf(a),0,-cosf(a)};}
            else         {lo=(Vec3){cosf(a)*m.ovalRadius,0, sinf(a)*m.ovalRadius};lt=(Vec3){-sinf(a),0, cosf(a)};}
            Vec3 wo=V3RotXYZ(lo,m.ovalPlaneRot), wt=V3RotXYZ(lt,m.ovalPlaneRot), wu=V3RotXYZ((Vec3){0,1,0},m.ovalPlaneRot);
            p.x+=wo.x;p.y+=wo.y;p.z+=wo.z;
            Vec3 fwd=V3Normalize(wt), right2=V3Normalize(V3Cross(wu,fwd)), up2=V3Cross(fwd,right2);
            pathMat4.m[0]=right2.x;pathMat4.m[1]=right2.y;pathMat4.m[2]=right2.z;
            pathMat4.m[4]=up2.x;   pathMat4.m[5]=up2.y;   pathMat4.m[6]=up2.z;
            pathMat4.m[8]=fwd.x;   pathMat4.m[9]=fwd.y;   pathMat4.m[10]=fwd.z;
            usePath=YES;
        }
        Mat4 model=Mat4Translate(p.x,p.y,p.z);
        if(usePath)            model=Mat4Mul(model,pathMat4);
        if(m.rotationDeg.x)    model=Mat4Mul(model,Mat4RotateX(m.rotationDeg.x));
        if(m.rotationDeg.y)    model=Mat4Mul(model,Mat4RotateY(m.rotationDeg.y));
        if(m.rotationDeg.z)    model=Mat4Mul(model,Mat4RotateZ(m.rotationDeg.z));

        A3DPOFMesh *pm=_meshCache[m.pofPath];
        if ((id)pm==[NSNull null]) pm=nil;
        if (!pm&&!_meshCache[m.pofPath]) {
            NSString *e=nil; pm=LoadPOF(m.pofPath,&e);
            _meshCache[m.pofPath] = pm ?: (id)[NSNull null];
        }
        if (pm) {
            NSMutableDictionary *children=[NSMutableDictionary dictionary];
            NSMutableArray *roots=[NSMutableArray array];
            for(A3DPOFSub *sub in pm.subs){
                if(sub.parent<0)[roots addObject:sub];
                else{NSNumber *pk=@(sub.parent);NSMutableArray *arr=children[pk];if(!arr){arr=[NSMutableArray array];children[pk]=arr;}[arr addObject:sub];}
            }
            if(roots.count==0&&pm.subs.count>0)[roots addObject:pm.subs[0]];
            NSSet *revSubs=nil;
            if(m.rotSync){
                NSMutableDictionary *axC=[NSMutableDictionary dictionary]; NSMutableSet *rs=[NSMutableSet set];
                for(A3DPOFSub *sub in pm.subs){if(!sub.rotates)continue;NSNumber *ax=@(sub.movementAxis);NSUInteger idx=[axC[ax] unsignedIntegerValue];BOOL reversed=(idx%2==0)?(BOOL)m.rotRev:(BOOL)!m.rotRev;if(reversed)[rs addObject:@(sub.sid)];axC[ax]=@(idx+1);}
                revSubs=rs;
            }
            for(A3DPOFSub *root in roots)
                [self _drawSub:root mesh:pm children:children elapsed:_elapsed reversed:revSubs modelMat:model];
        } else {
            Mat4 mvp=Mat4Mul(_proj,Mat4Mul(_view,model));
            glUseProgram(_flatShader); glUniformMatrix4fv(_uMVP,1,GL_FALSE,mvp.m);
            glUniform1f(_uPointSize,1.0f); glUniform4f(_uColorMul,1,0.1f,0.1f,1);
            glDisable(GL_CULL_FACE); glBindVertexArray(_cubeVAO); glDrawArrays(GL_TRIANGLES,0,36);
            glBindVertexArray(0); glEnable(GL_CULL_FACE); glUseProgram(0);
        }
    }

    /* Read pixels back (bottom-to-top in GL → flip for Cairo top-to-bottom) */
    int w=rec.w, h=rec.h;
    NSMutableData *px=[NSMutableData dataWithLength:(NSUInteger)(w*h*4)];
    uint8_t *pixels=(uint8_t*)px.mutableBytes;
    glBindFramebuffer(GL_READ_FRAMEBUFFER, rec.fbo);
    /* GLES3 gives RGBA; flip rows and swap R↔B to produce Cairo ARGB32 */
    glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);

    /* Create Cairo surface, flipping rows and converting RGBA → BGRA */
    cairo_surface_t *surf = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
    cairo_surface_flush(surf);
    uint8_t *dst = cairo_image_surface_get_data(surf);
    int stride   = cairo_image_surface_get_stride(surf);
    for (int row = 0; row < h; row++) {
        const uint8_t *src = pixels + (size_t)(h-1-row) * (size_t)(w*4);
        uint8_t *d = dst + row * stride;
        for (int x = 0; x < w; x++, src += 4, d += 4) {
            d[0] = src[2]; d[1] = src[1]; d[2] = src[0]; d[3] = src[3];
        }
    }
    cairo_surface_mark_dirty(surf);

    /* Push to wlr_scene_buffer */
    struct a3d_bg_buffer *buf = a3d_buf_create(surf);
    if (!buf) return;

    struct wlr_box box = {0};
    wlr_output_layout_get_box(_layout, rec.output, &box);

    if (rec.node == NULL) {
        struct wlr_scene_buffer *sb = wlr_scene_buffer_create(_bgTree, &buf->base);
        wlr_scene_node_set_position(&sb->node, box.x, box.y);
        rec.node = sb;
    } else {
        wlr_scene_buffer_set_buffer(rec.node, &buf->base);
        wlr_scene_node_set_position(&rec.node->node, box.x, box.y);
        wlr_scene_node_set_enabled(&rec.node->node, true);
    }
    wlr_buffer_drop(&buf->base);
}

/* -------------------------------------------------------------------------
 * Render frame tick
 * ---------------------------------------------------------------------- */
- (void)_renderFrame
{
    if (!_scene || _eglCtx == EGL_NO_CONTEXT) goto rearm;

    /* Save compositor's current EGL state */
    EGLDisplay prevDpy = eglGetCurrentDisplay();
    EGLSurface prevDraw = eglGetCurrentSurface(EGL_DRAW);
    EGLSurface prevRead = eglGetCurrentSurface(EGL_READ);
    EGLContext prevCtx  = eglGetCurrentContext();

    if (!eglMakeCurrent(_eglDpy, _eglPbuf, _eglPbuf, _eglCtx)) {
        wlr_log(WLR_ERROR, "3dbg: eglMakeCurrent failed: 0x%x", eglGetError());
        goto rearm;
    }

    if (!_glReady) [self _initGL];

    /* Advance elapsed time */
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    _elapsed += (float)(now - _lastTick);
    _lastTick = now;

    for (_A3DOutput *rec in _outputs)
        [self _renderToOutput:rec];

    glFlush();

    /* Restore compositor's EGL context */
    if (prevCtx != EGL_NO_CONTEXT)
        eglMakeCurrent(prevDpy, prevDraw, prevRead, prevCtx);
    else
        eglMakeCurrent(_eglDpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);

rearm:
    if (_timer && _timer->source)
        wl_event_source_timer_update(_timer->source, 33); /* ~30 fps */
}

/* -------------------------------------------------------------------------
 * Timer management
 * ---------------------------------------------------------------------- */
- (void)_startTimer
{
    if (_timer) return;
    _timer = (struct a3d_timer_ctx *)calloc(1, sizeof(*_timer));
    if (!_timer) return;
    _timer->bg     = (__bridge void *)self;
    _timer->source = wl_event_loop_add_timer(_loop, a3d_timer_cb, _timer);
    wl_event_source_timer_update(_timer->source, 33);
}

- (void)_stopTimer
{
    if (!_timer) return;
    if (_timer->source) { wl_event_source_remove(_timer->source); _timer->source = NULL; }
    free(_timer); _timer = NULL;
}

/* -------------------------------------------------------------------------
 * Public interface
 * ---------------------------------------------------------------------- */
- (void)handleOutputAdded:(struct wlr_output *)output
{
    _A3DOutput *rec = [_A3DOutput new];
    rec.output = output;
    [_outputs addObject:rec];

    if (_eglCtx == EGL_NO_CONTEXT) return;

    EGLDisplay prevDpy=eglGetCurrentDisplay(); EGLSurface prevDraw=eglGetCurrentSurface(EGL_DRAW);
    EGLSurface prevRead=eglGetCurrentSurface(EGL_READ); EGLContext prevCtx=eglGetCurrentContext();
    eglMakeCurrent(_eglDpy, _eglPbuf, _eglPbuf, _eglCtx);
    if (!_glReady) [self _initGL];
    [self _createFBOForOutput:rec];
    if (prevCtx!=EGL_NO_CONTEXT) eglMakeCurrent(prevDpy,prevDraw,prevRead,prevCtx);
    else eglMakeCurrent(_eglDpy,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT);
}

- (void)handleOutputRemoved:(struct wlr_output *)output
{
    for (NSUInteger i = 0; i < _outputs.count; i++) {
        _A3DOutput *rec = _outputs[i];
        if (rec.output != output) continue;
        if (_eglCtx != EGL_NO_CONTEXT) {
            EGLDisplay prevDpy=eglGetCurrentDisplay(); EGLSurface prevDraw=eglGetCurrentSurface(EGL_DRAW);
            EGLSurface prevRead=eglGetCurrentSurface(EGL_READ); EGLContext prevCtx=eglGetCurrentContext();
            eglMakeCurrent(_eglDpy,_eglPbuf,_eglPbuf,_eglCtx);
            [self _destroyFBOForOutput:rec];
            if (prevCtx!=EGL_NO_CONTEXT) eglMakeCurrent(prevDpy,prevDraw,prevRead,prevCtx);
            else eglMakeCurrent(_eglDpy,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT);
        }
        if (rec.node) { wlr_scene_node_destroy(&rec.node->node); rec.node=NULL; }
        [_outputs removeObjectAtIndex:i];
        return;
    }
}

- (void)stop
{
    [self _stopTimer];
    if (_eglCtx != EGL_NO_CONTEXT) {
        eglMakeCurrent(_eglDpy, _eglPbuf, _eglPbuf, _eglCtx);
        for (_A3DOutput *rec in _outputs) [self _destroyFBOForOutput:rec];
        if (_shader)     { glDeleteProgram(_shader);     _shader=0; }
        if (_flatShader) { glDeleteProgram(_flatShader); _flatShader=0; }
        if (_starsVAO)   { glDeleteVertexArrays(1,&_starsVAO); glDeleteBuffers(1,&_starsVBO); _starsVAO=_starsVBO=0; }
        if (_axesVAO)    { glDeleteVertexArrays(1,&_axesVAO);  glDeleteBuffers(1,&_axesVBO);  _axesVAO=_axesVBO=0; }
        if (_cubeVAO)    { glDeleteVertexArrays(1,&_cubeVAO);  glDeleteBuffers(1,&_cubeVBO);  _cubeVAO=_cubeVBO=0; }
        _glReady=NO;
        eglMakeCurrent(_eglDpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    }
    if (_eglPbuf!=EGL_NO_SURFACE) { eglDestroySurface(_eglDpy,_eglPbuf); _eglPbuf=EGL_NO_SURFACE; }
    if (_eglCtx!=EGL_NO_CONTEXT)  { eglDestroyContext(_eglDpy,_eglCtx);  _eglCtx=EGL_NO_CONTEXT; }
    for (_A3DOutput *rec in _outputs)
        if (rec.node) { wlr_scene_node_destroy(&rec.node->node); rec.node=NULL; }
    [_outputs removeAllObjects];
}

@end

/* Timer callback — fires on the wl_event_loop thread */
static int a3d_timer_cb(void *data)
{
    struct a3d_timer_ctx *ctx = data;
    Ambrosia3DBackground *bg = (__bridge Ambrosia3DBackground *)ctx->bg;
    [bg _renderFrame];
    return 0;
}
