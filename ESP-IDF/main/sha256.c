#include "sha256.h"
#include <string.h>
static const uint32_t k[64] = {
 0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
 0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
 0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
 0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
 0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
 0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
 0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
 0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2};
static uint32_t rotr(uint32_t v, unsigned n) { return (v >> n) | (v << (32 - n)); }
static void block(uint32_t h[8], const uint8_t *b) {
    uint32_t w[64];
    for (int i=0;i<16;++i) w[i]=(uint32_t)b[i*4]<<24|(uint32_t)b[i*4+1]<<16|(uint32_t)b[i*4+2]<<8|b[i*4+3];
    for (int i=16;i<64;++i) {
        uint32_t x=w[i-15],y=w[i-2];
        w[i]=w[i-16]+(rotr(x,7)^rotr(x,18)^(x>>3))+w[i-7]+(rotr(y,17)^rotr(y,19)^(y>>10));
    }
    uint32_t a=h[0],b0=h[1],c=h[2],d=h[3],e=h[4],f=h[5],g=h[6],hh=h[7];
    for (int i=0;i<64;++i) {
        uint32_t t1=hh+(rotr(e,6)^rotr(e,11)^rotr(e,25))+((e&f)^((~e)&g))+k[i]+w[i];
        uint32_t t2=(rotr(a,2)^rotr(a,13)^rotr(a,22))+((a&b0)^(a&c)^(b0&c));
        hh=g;g=f;f=e;e=d+t1;d=c;c=b0;b0=a;a=t1+t2;
    }
    h[0]+=a;h[1]+=b0;h[2]+=c;h[3]+=d;h[4]+=e;h[5]+=f;h[6]+=g;h[7]+=hh;
}
void ink_sha256(const uint8_t *data, size_t size, uint8_t result[32]) {
    uint32_t h[8]={0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19};
    size_t original=size;
    while(size>=64) {block(h,data);data+=64;size-=64;}
    uint8_t tail[128]={0};memcpy(tail,data,size);tail[size]=0x80;
    size_t blocks=size<56?64:128;uint64_t bits=(uint64_t)original*8;
    for(int i=0;i<8;++i) tail[blocks-1-i]=(uint8_t)(bits>>(i*8));
    block(h,tail);if(blocks==128) block(h,tail+64);
    for(int i=0;i<8;++i) for(int j=0;j<4;++j) result[i*4+j]=(uint8_t)(h[i]>>(24-j*8));
}
void ink_sha256_hex(const uint8_t *data, size_t size, char result[65]) {
    static const char digits[]="0123456789abcdef";uint8_t hash[32];ink_sha256(data,size,hash);
    for(int i=0;i<32;++i) {result[i*2]=digits[hash[i]>>4];result[i*2+1]=digits[hash[i]&15];}result[64]=0;
}
