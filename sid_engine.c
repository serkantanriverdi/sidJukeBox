// cSID by Hermit (Mihaly Horvath), (Year 2016..2017) http://hermit.sidrip.com
// License: WTF - Do what the fuck you want with this code, but please mention me as its original author.
// Adapted for macOS/iOS by removing SDL dependency

#include <stdlib.h>
#include <stdio.h>
#include <math.h>
#include "sid_engine.h"

#define C64_PAL_CPUCLK 985248
#define SID_CHANNEL_AMOUNT 3
#define MAX_DATA_LEN 65536
#define PAL_FRAMERATE 49.4
#define DEFAULT_SAMPLERATE 44100

int OUTPUT_SCALEDOWN = SID_CHANNEL_AMOUNT * 16 + 26;

enum { GATE_BITMASK=0x01, SYNC_BITMASK=0x02, RING_BITMASK=0x04,
    TEST_BITMASK=0x08, TRI_BITMASK=0x10, SAW_BITMASK=0x20,
    PULSE_BITMASK=0x40, NOISE_BITMASK=0x80, HOLDZERO_BITMASK=0x10,
    DECAYSUSTAIN_BITMASK=0x40, ATTACK_BITMASK=0x80, LOWPASS_BITMASK=0x10,
    BANDPASS_BITMASK=0x20, HIGHPASS_BITMASK=0x40, OFF3_BITMASK=0x80 };

const byte FILTSW[9] = {1,2,4,1,2,4,1,2,4};
byte ADSRstate[9], expcnt[9], envcnt[9], sourceMSBrise[9];
unsigned int clock_ratio=22, ratecnt[9], prevwfout[9];
unsigned long int phaseaccu[9], prevaccu[9], sourceMSB[3], noise_LFSR[9];
long int prevlowpass[3], prevbandpass[3];
float cutoff_ratio_8580, cutoff_ratio_6581, cutoff_bias_6581;
int SIDamount=1, SID_model[3]={8580,8580,8580}, requested_SID_model=-1, sampleratio;
byte filedata[MAX_DATA_LEN], memory[MAX_DATA_LEN], timermode[0x20];
static byte SIDtitle_buf[0x20], SIDauthor_buf[0x20], SIDinfo_buf[0x20];
int subtune=0;
unsigned int initaddr, playaddr, playaddf, SID_address[3]={0xD400,0,0};
long int samplerate = DEFAULT_SAMPLERATE;
int framecnt=0, frame_sampleperiod = DEFAULT_SAMPLERATE/PAL_FRAMERATE;
const byte flagsw[]={0x01,0x21,0x04,0x24,0x00,0x40,0x08,0x28}, branchflag[]={0x80,0x40,0x01,0x02};
unsigned int PC=0, pPC=0, addr=0, storadd=0;
short int A=0, T=0, SP=0xFF;
byte X=0, Y=0, IR=0, ST=0x00;
char CPUtime=0, cycles=0, finished=0, dynCIA=0;
static int subtune_amount=0;

unsigned int TriSaw_8580[4096], PulseSaw_8580[4096], PulseTriSaw_8580[4096];
int ADSRperiods[16] = {9, 32, 63, 95, 149, 220, 267, 313, 392, 977, 1954, 3126, 3907, 11720, 19532, 31251};
const byte ADSR_exptable[256] = {1, 30, 30, 30, 30, 30, 30, 16, 16, 16, 16, 16, 16, 16, 16, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 4, 4, 4, 4, 4,
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 };


void cSID_init(int sr)
{
    int i;
    samplerate = sr;
    clock_ratio = round(C64_PAL_CPUCLK/(float)samplerate);
    sampleratio = clock_ratio;
    cutoff_ratio_8580 = -2 * 3.14 * (12500.0 / 2048) / C64_PAL_CPUCLK;
    cutoff_ratio_6581 = -2 * 3.14 * (20000.0 / 2048) / C64_PAL_CPUCLK;
    cutoff_bias_6581 = 1 - exp( -2 * 3.14 * 220 / C64_PAL_CPUCLK );

    createCombinedWF(TriSaw_8580, 0.8, 2.4, 0.64);
    createCombinedWF(PulseSaw_8580, 1.4, 1.9, 0.68);
    createCombinedWF(PulseTriSaw_8580, 0.8, 2.5, 0.64);

    for(i = 0; i < 9; i++) {
        ADSRstate[i] = HOLDZERO_BITMASK; envcnt[i] = 0; ratecnt[i] = 0;
        phaseaccu[i] = 0; prevaccu[i] = 0; expcnt[i] = 0;
        noise_LFSR[i] = 0x7FFFF8; prevwfout[i] = 0;
    }
    for(i = 0; i < 3; i++) {
        sourceMSBrise[i] = 0; sourceMSB[i] = 0;
        prevlowpass[i] = 0; prevbandpass[i] = 0;
    }
    initSID();
}


void initSID() {
    int i;
    for(i=0xD400;i<=0xD7FF;i++) memory[i]=0;
    for(i=0xDE00;i<=0xDFFF;i++) memory[i]=0;
    for(i=0;i<9;i++) {ADSRstate[i]=HOLDZERO_BITMASK; ratecnt[i]=envcnt[i]=expcnt[i]=0;}
}


void initCPU (unsigned int mempos) { PC=mempos; A=0; X=0; Y=0; ST=0; SP=0xFF; }


byte CPU ()
{
    IR=memory[PC]; cycles=2; storadd=0;
    if(IR&1) {
        switch (IR&0x1F) {
            case 1: case 3: addr = memory[memory[++PC]+X] + memory[memory[PC]+X+1]*256; cycles=6; break;
            case 0x11: case 0x13: addr = memory[memory[++PC]] + memory[memory[PC]+1]*256 + Y; cycles=6; break;
            case 0x19: case 0x1B: addr = memory[++PC] + memory[++PC]*256 + Y; cycles=5; break;
            case 0x1D: addr = memory[++PC] + memory[++PC]*256 + X; cycles=5; break;
            case 0xD: case 0xF: addr = memory[++PC] + memory[++PC]*256; cycles=4; break;
            case 0x15: addr = memory[++PC] + X; cycles=4; break;
            case 5: case 7: addr = memory[++PC]; cycles=3; break;
            case 0x17: if ((IR&0xC0)!=0x80) { addr = memory[++PC] + X; cycles=4; }
                       else { addr = memory[++PC] + Y; cycles=4; } break;
            case 0x1F: if ((IR&0xC0)!=0x80) { addr = memory[++PC] + memory[++PC]*256 + X; cycles=5; }
                       else { addr = memory[++PC] + memory[++PC]*256 + Y; cycles=5; } break;
            case 9: case 0xB: addr = ++PC; cycles=2;
        }
        addr&=0xFFFF;
        switch (IR&0xE0) {
            case 0x60: if ((IR&0x1F)!=0xB) { if((IR&3)==3) {T=(memory[addr]>>1)+(ST&1)*128; ST&=124; ST|=(T&1); memory[addr]=T; cycles+=2;}
                        T=A; A+=memory[addr]+(ST&1); ST&=60; ST|=(A&128)|(A>255); A&=0xFF; ST |= (!A)<<1 | ( !((T^memory[addr])&0x80) & ((T^A)&0x80) ) >> 1; }
                       else { A&=memory[addr]; T+=memory[addr]+(ST&1); ST&=60; ST |= (T>255) | ( !((A^memory[addr])&0x80) & ((T^A)&0x80) ) >> 1;
                        T=A; A=(A>>1)+(ST&1)*128; ST|=(A&128)|(T>127); ST|=(!A)<<1; } break;
            case 0xE0: if((IR&3)==3 && (IR&0x1F)!=0xB) {memory[addr]++;cycles+=2;} T=A; A-=memory[addr]+!(ST&1);
                       ST&=60; ST|=(A&128)|(A>=0); A&=0xFF; ST |= (!A)<<1 | ( ((T^memory[addr])&0x80) & ((T^A)&0x80) ) >> 1; break;
            case 0xC0: if((IR&0x1F)!=0xB) { if ((IR&3)==3) {memory[addr]--; cycles+=2;} T=A-memory[addr]; }
                       else {X=T=(A&X)-memory[addr];} ST&=124;ST|=(!(T&0xFF))<<1|(T&128)|(T>=0); break;
            case 0x00: if ((IR&0x1F)!=0xB) { if ((IR&3)==3) {ST&=124; ST|=(memory[addr]>127); memory[addr]<<=1; cycles+=2;}
                        A|=memory[addr]; ST&=125;ST|=(!A)<<1|(A&128); }
                       else {A&=memory[addr]; ST&=124;ST|=(!A)<<1|(A&128)|(A>127);} break;
            case 0x20: if ((IR&0x1F)!=0xB) { if ((IR&3)==3) {T=(memory[addr]<<1)+(ST&1); ST&=124; ST|=(T>255); T&=0xFF; memory[addr]=T; cycles+=2;}
                        A&=memory[addr]; ST&=125; ST|=(!A)<<1|(A&128); }
                       else {A&=memory[addr]; ST&=124;ST|=(!A)<<1|(A&128)|(A>127);} break;
            case 0x40: if ((IR&0x1F)!=0xB) { if ((IR&3)==3) {ST&=124; ST|=(memory[addr]&1); memory[addr]>>=1; cycles+=2;}
                        A^=memory[addr]; ST&=125;ST|=(!A)<<1|(A&128); }
                       else {A&=memory[addr]; ST&=124; ST|=(A&1); A>>=1; A&=0xFF; ST|=(A&128)|((!A)<<1); } break;
            case 0xA0: if ((IR&0x1F)!=0x1B) { A=memory[addr]; if((IR&3)==3) X=A; }
                       else {A=X=SP=memory[addr]&SP;} ST&=125; ST|=((!A)<<1) | (A&128); break;
            case 0x80: if ((IR&0x1F)==0xB) { A = X & memory[addr]; ST&=125; ST|=(A&128) | ((!A)<<1); }
                       else if ((IR&0x1F)==0x1B) { SP=A&X; memory[addr]=SP&((addr>>8)+1); }
                       else {memory[addr]=A & (((IR&3)==3)?X:0xFF); storadd=addr;} break;
        }
    }
    else if(IR&2) {
        switch (IR&0x1F) {
            case 0x1E: addr = memory[++PC] + memory[++PC]*256 + ( ((IR&0xC0)!=0x80) ? X:Y ); cycles=5; break;
            case 0xE: addr = memory[++PC] + memory[++PC]*256; cycles=4; break;
            case 0x16: addr = memory[++PC] + ( ((IR&0xC0)!=0x80) ? X:Y ); cycles=4; break;
            case 6: addr = memory[++PC]; cycles=3; break;
            case 2: addr = ++PC; cycles=2;
        }
        addr&=0xFFFF;
        switch (IR&0xE0) {
            case 0x00: ST&=0xFE; case 0x20: if((IR&0xF)==0xA) { A=(A<<1)+(ST&1); ST&=124;ST|=(A&128)|(A>255); A&=0xFF; ST|=(!A)<<1; }
              else { T=(memory[addr]<<1)+(ST&1); ST&=124;ST|=(T&128)|(T>255); T&=0xFF; ST|=(!T)<<1; memory[addr]=T; cycles+=2; } break;
            case 0x40: ST&=0xFE; case 0x60: if((IR&0xF)==0xA) { T=A; A=(A>>1)+(ST&1)*128; ST&=124;ST|=(A&128)|(T&1); A&=0xFF; ST|=(!A)<<1; }
              else { T=(memory[addr]>>1)+(ST&1)*128; ST&=124;ST|=(T&128)|(memory[addr]&1); T&=0xFF; ST|=(!T)<<1; memory[addr]=T; cycles+=2; } break;
            case 0xC0: if(IR&4) { memory[addr]--; ST&=125;ST|=(!memory[addr])<<1|(memory[addr]&128); cycles+=2; }
              else {X--; X&=0xFF; ST&=125;ST|=(!X)<<1|(X&128);} break;
            case 0xA0: if((IR&0xF)!=0xA) X=memory[addr]; else if(IR&0x10) {X=SP;break;} else X=A; ST&=125;ST|=(!X)<<1|(X&128); break;
            case 0x80: if(IR&4) {memory[addr]=X;storadd=addr;} else if(IR&0x10) SP=X; else {A=X; ST&=125;ST|=(!A)<<1|(A&128);} break;
            case 0xE0: if(IR&4) { memory[addr]++; ST&=125;ST|=(!memory[addr])<<1|(memory[addr]&128); cycles+=2; } break;
        }
    }
    else if((IR&0xC)==8) {
        switch (IR&0xF0) {
            case 0x60: SP++; SP&=0xFF; A=memory[0x100+SP]; ST&=125;ST|=(!A)<<1|(A&128); cycles=4; break;
            case 0xC0: Y++; Y&=0xFF; ST&=125;ST|=(!Y)<<1|(Y&128); break;
            case 0xE0: X++; X&=0xFF; ST&=125;ST|=(!X)<<1|(X&128); break;
            case 0x80: Y--; Y&=0xFF; ST&=125;ST|=(!Y)<<1|(Y&128); break;
            case 0x00: memory[0x100+SP]=ST; SP--; SP&=0xFF; cycles=3; break;
            case 0x20: SP++; SP&=0xFF; ST=memory[0x100+SP]; cycles=4; break;
            case 0x40: memory[0x100+SP]=A; SP--; SP&=0xFF; cycles=3; break;
            case 0x90: A=Y; ST&=125;ST|=(!A)<<1|(A&128); break;
            case 0xA0: Y=A; ST&=125;ST|=(!Y)<<1|(Y&128); break;
            default: if(flagsw[IR>>5]&0x20) ST|=(flagsw[IR>>5]&0xDF); else ST&=255-(flagsw[IR>>5]&0xDF);
        }
    }
    else {
        if ((IR&0x1F)==0x10) { PC++; T=memory[PC]; if(T&0x80) T-=0x100;
            if(IR&0x20) {if (ST&branchflag[IR>>6]) {PC+=T;cycles=3;}} else {if (!(ST&branchflag[IR>>6])) {PC+=T;cycles=3;}} }
        else {
            switch (IR&0x1F) {
                case 0: addr = ++PC; cycles=2; break;
                case 0x1C: addr = memory[++PC] + memory[++PC]*256 + X; cycles=5; break;
                case 0xC: addr = memory[++PC] + memory[++PC]*256; cycles=4; break;
                case 0x14: addr = memory[++PC] + X; cycles=4; break;
                case 4: addr = memory[++PC]; cycles=3;
            }
            addr&=0xFFFF;
            switch (IR&0xE0) {
                case 0x00: memory[0x100+SP]=PC%256; SP--;SP&=0xFF; memory[0x100+SP]=PC/256; SP--;SP&=0xFF; memory[0x100+SP]=ST; SP--;SP&=0xFF;
                  PC = memory[0xFFFE]+memory[0xFFFF]*256-1; cycles=7; break;
                case 0x20: if(IR&0xF) { ST &= 0x3D; ST |= (memory[addr]&0xC0) | ( !(A&memory[addr]) )<<1; }
                  else { memory[0x100+SP]=(PC+2)%256; SP--;SP&=0xFF; memory[0x100+SP]=(PC+2)/256; SP--;SP&=0xFF; PC=memory[addr]+memory[addr+1]*256-1; cycles=6; } break;
                case 0x40: if(IR&0xF) { PC = addr-1; cycles=3; }
                  else { if(SP>=0xFF) return 0xFE; SP++;SP&=0xFF; ST=memory[0x100+SP]; SP++;SP&=0xFF; T=memory[0x100+SP]; SP++;SP&=0xFF; PC=memory[0x100+SP]+T*256-1; cycles=6; } break;
                case 0x60: if(IR&0xF) { PC = memory[addr]+memory[addr+1]*256-1; cycles=5; }
                  else { if(SP>=0xFF) return 0xFF; SP++;SP&=0xFF; T=memory[0x100+SP]; SP++;SP&=0xFF; PC=memory[0x100+SP]+T*256-1; cycles=6; } break;
                case 0xC0: T=Y-memory[addr]; ST&=124;ST|=(!(T&0xFF))<<1|(T&128)|(T>=0); break;
                case 0xE0: T=X-memory[addr]; ST&=124;ST|=(!(T&0xFF))<<1|(T&128)|(T>=0); break;
                case 0xA0: Y=memory[addr]; ST&=125;ST|=(!Y)<<1|(Y&128); break;
                case 0x80: memory[addr]=Y; storadd=addr;
            }
        }
    }
    PC++;
    return 0;
}


int SID(char num, unsigned int baseaddr)
{
    static byte channel, ctrl, SR, prevgate, wf, test, filterctrl_prescaler[3];
    static byte *sReg, *vReg;
    static unsigned int period, accuadd, pw, wfout;
    static unsigned long int MSB;
    static int nonfilt, filtin, cutoff[3], resonance[3];
    static long int output, filtout, ftmp;

    filtin=nonfilt=0; sReg = &memory[baseaddr]; vReg = sReg;
    for (channel = num * SID_CHANNEL_AMOUNT ; channel < (num + 1) * SID_CHANNEL_AMOUNT ; channel++, vReg += 7) {
        ctrl = vReg[4];
        {
            SR = vReg[6];
            prevgate = (ADSRstate[channel] & GATE_BITMASK);
            if (prevgate != (ctrl & GATE_BITMASK)) {
                if (prevgate) { ADSRstate[channel] &= 0xFF - (GATE_BITMASK | ATTACK_BITMASK | DECAYSUSTAIN_BITMASK); }
                else { ADSRstate[channel] = (GATE_BITMASK | ATTACK_BITMASK | DECAYSUSTAIN_BITMASK); }
            }
            if (ADSRstate[channel] & ATTACK_BITMASK) period = ADSRperiods[ vReg[5] >> 4 ];
            else if (ADSRstate[channel] & DECAYSUSTAIN_BITMASK) period = ADSRperiods[ vReg[5] & 0xF ];
            else period = ADSRperiods[ SR & 0xF ];
            ratecnt[channel]++; ratecnt[channel]&=0x7FFF;
            if (ratecnt[channel] == period) {
                ratecnt[channel] = 0;
                if ((ADSRstate[channel] & ATTACK_BITMASK) || ++expcnt[channel] == ADSR_exptable[envcnt[channel]]) {
                    expcnt[channel] = 0;
                    if (!(ADSRstate[channel] & HOLDZERO_BITMASK)) {
                        if (ADSRstate[channel] & ATTACK_BITMASK) {
                            envcnt[channel]++;
                            if (envcnt[channel]==0xFF) ADSRstate[channel] &= 0xFF - ATTACK_BITMASK;
                        }
                        else if ( !(ADSRstate[channel] & DECAYSUSTAIN_BITMASK) || envcnt[channel] != (SR>>4)+(SR&0xF0) ) {
                            envcnt[channel]--;
                            if (envcnt[channel]==0) ADSRstate[channel] |= HOLDZERO_BITMASK;
                        }
                    }
                }
            }
        }
        test = ctrl & TEST_BITMASK;
        wf = ctrl & 0xF0;
        accuadd = (vReg[0] + vReg[1] * 256);
        if (test || ((ctrl & SYNC_BITMASK) && sourceMSBrise[num])) { phaseaccu[channel] = 0; }
        else { phaseaccu[channel] += accuadd; phaseaccu[channel]&=0xFFFFFF; }
        MSB = phaseaccu[channel] & 0x800000;
        sourceMSBrise[num] = (MSB > (prevaccu[channel] & 0x800000)) ? 1 : 0;
        if (wf & NOISE_BITMASK) {
            int tmp = noise_LFSR[channel];
            if (((phaseaccu[channel] & 0x100000) != (prevaccu[channel] & 0x100000))) {
                int step = (tmp & 0x400000) ^ ((tmp & 0x20000) << 5);
                tmp = ((tmp << 1) + (step ? 1 : test)) & 0x7FFFFF;
                noise_LFSR[channel] = tmp;
            }
            wfout = (wf & 0x70) ? 0 : ((tmp & 0x100000) >> 5) + ((tmp & 0x40000) >> 4) + ((tmp & 0x4000) >> 1) + ((tmp & 0x800) << 1) + ((tmp & 0x200) << 2) + ((tmp & 0x20) << 5) + ((tmp & 0x04) << 7) + ((tmp & 0x01) << 8);
        } else if (wf & PULSE_BITMASK) {
            pw = (vReg[2] + (vReg[3] & 0xF) * 256) * 16;
            int tmp = phaseaccu[channel] >> 8;
            if (wf == PULSE_BITMASK) { if (test || tmp>=pw) wfout = 0xFFFF; else { wfout=0; } }
            else {
                wfout = (tmp >= pw || test) ? 0xFFFF : 0;
                if (wf & TRI_BITMASK) {
                    if (wf & SAW_BITMASK) { wfout = (wfout) ? combinedWF(num, channel, PulseTriSaw_8580, tmp >> 4, 1) : 0; }
                    else { tmp = phaseaccu[channel] ^ (ctrl & RING_BITMASK ? sourceMSB[num] : 0);
                        wfout = (wfout) ? combinedWF(num, channel, PulseSaw_8580, (tmp ^ (tmp & 0x800000 ? 0xFFFFFF : 0)) >> 11, 0) : 0; }
                }
                else if (wf & SAW_BITMASK) wfout = (wfout) ? combinedWF(num, channel, PulseSaw_8580, tmp >> 4, 1) : 0;
            }
        }
        else if (wf & SAW_BITMASK) {
            wfout = phaseaccu[channel] >> 8;
            if (wf & TRI_BITMASK) wfout = combinedWF(num, channel, TriSaw_8580, wfout >> 4, 1);
        }
        else if (wf & TRI_BITMASK) {
            int tmp = phaseaccu[channel] ^ (ctrl & RING_BITMASK ? sourceMSB[num] : 0);
            wfout = (tmp ^ (tmp & 0x800000 ? 0xFFFFFF : 0)) >> 7;
        }
        if (wf) prevwfout[channel] = wfout; else { wfout = prevwfout[channel]; }
        prevaccu[channel] = phaseaccu[channel];
        sourceMSB[num] = MSB;
        if (sReg[0x17] & FILTSW[channel]) filtin += ((long int)wfout - 0x8000) * envcnt[channel] / 256;
        else if ((FILTSW[channel] != 4) || !(sReg[0x18] & OFF3_BITMASK))
                nonfilt += ((long int)wfout - 0x8000) * envcnt[channel] / 256;
    }
    if(num==0) { sReg[0x1B]=wfout>>8; sReg[0x1C]=envcnt[3]; }

    filterctrl_prescaler[num]--;
    if (filterctrl_prescaler[num]==0) {
        filterctrl_prescaler[num]=clock_ratio;
        cutoff[num] = 2 + sReg[0x16] * 8 + (sReg[0x15] & 7);
        if (SID_model[num] == 8580) {
            cutoff[num] = ( 1 - exp(cutoff[num] * cutoff_ratio_8580) ) * 0x10000;
            resonance[num] = ( pow(2, ((4 - (sReg[0x17] >> 4)) / 8.0)) ) * 0x100;
        } else {
            cutoff[num] = ( cutoff_bias_6581 + ( (cutoff[num] < 192) ? 0 : 1 - exp((cutoff[num]-192) * cutoff_ratio_6581) ) ) * 0x10000;
            resonance[num] = ( (sReg[0x17] > 0x5F) ? 8.0 / (sReg[0x17] >> 4) : 1.41 ) * 0x100;
        }
    }
    filtout=0;
    ftmp = filtin + prevbandpass[num] * resonance[num] / 0x100 + prevlowpass[num];
    if (sReg[0x18] & HIGHPASS_BITMASK) filtout -= ftmp;
    ftmp = prevbandpass[num] - ftmp * cutoff[num] / 0x10000;
    prevbandpass[num] = ftmp;
    if (sReg[0x18] & BANDPASS_BITMASK) filtout -= ftmp;
    ftmp = prevlowpass[num] + ftmp * cutoff[num] / 0x10000;
    prevlowpass[num] = ftmp;
    if (sReg[0x18] & LOWPASS_BITMASK) filtout += ftmp;

    output = (nonfilt+filtout) * (sReg[0x18]&0xF) / OUTPUT_SCALEDOWN;
    if (output>=32767) output=32767; else if (output<=-32768) output=-32768;
    return (int)output;
}


unsigned int combinedWF(char num, char channel, unsigned int* wfarray, int index, char differ6581)
{
    if(differ6581 && SID_model[num]==6581) index&=0x7FF;
    return wfarray[index];
}

void createCombinedWF(unsigned int* wfarray, float bitmul, float bitstrength, float treshold)
{
    int i,j,k;
    for (i=0; i<4096; i++) { wfarray[i]=0; for (j=0; j<12;j++) {
        float bitlevel=0; for (k=0; k<12; k++) {
            bitlevel += ( bitmul/pow(bitstrength,fabs(k-j)) ) * (((i>>k)&1)-0.5) ;
        }
        wfarray[i] += (bitlevel>=treshold)? pow(2,j) : 0; } wfarray[i]*=12; }
}


// --- High-level API ---

int sid_load(const byte *data, int datalen, int subtune_num)
{
    unsigned int i, offs, loadaddr;
    int strend;

    if (datalen < 0x7C) return -1;
    for (i = 0; i < (unsigned int)datalen && i < MAX_DATA_LEN; i++) filedata[i] = data[i];

    offs = filedata[7];
    loadaddr = filedata[8]+filedata[9] ? filedata[8]*256+filedata[9] : filedata[offs]+filedata[offs+1]*256;

    for (i=0; i<32; i++) { timermode[31-i] = (filedata[0x12+(i>>3)] & (byte)pow(2,7-i%8))?1:0; }
    for (i=0; i<MAX_DATA_LEN; i++) memory[i]=0;
    for (i=offs+2; i<(unsigned int)datalen; i++) { if (loadaddr+i-(offs+2)<MAX_DATA_LEN) memory[loadaddr+i-(offs+2)]=filedata[i]; }

    strend=1; for(i=0; i<32; i++) { if(strend!=0) strend=SIDtitle_buf[i]=filedata[0x16+i]; else SIDtitle_buf[i]=0; }
    strend=1; for(i=0; i<32; i++) { if(strend!=0) strend=SIDauthor_buf[i]=filedata[0x36+i]; else SIDauthor_buf[i]=0; }
    strend=1; for(i=0; i<32; i++) { if(strend!=0) strend=SIDinfo_buf[i]=filedata[0x56+i]; else SIDinfo_buf[i]=0; }

    initaddr = filedata[0xA]+filedata[0xB] ? filedata[0xA]*256+filedata[0xB] : loadaddr;
    playaddr = playaddf = filedata[0xC]*256+filedata[0xD];
    subtune_amount = filedata[0xF];

    int preferred = (filedata[0x77]&0x30)>=0x20 ? 8580 : 6581;
    SID_model[0] = preferred;

    SID_address[1] = filedata[0x7A]>=0x42 && (filedata[0x7A]<0x80 || filedata[0x7A]>=0xE0) ? 0xD000+filedata[0x7A]*16 : 0;
    SID_address[2] = filedata[0x7B]>=0x42 && (filedata[0x7B]<0x80 || filedata[0x7B]>=0xE0) ? 0xD000+filedata[0x7B]*16 : 0;
    SIDamount = 1+(SID_address[1]>0)+(SID_address[2]>0);

    subtune = subtune_num;
    if (subtune < 0 || subtune >= subtune_amount) subtune = 0;

    // Init
    long int timeout;
    initCPU(initaddr); initSID(); A=subtune; memory[1]=0x37; memory[0xDC05]=0;
    for(timeout=100000;timeout>=0;timeout--) { if (CPU()) break; }
    if (timermode[subtune] || memory[0xDC05]) {
        if (!memory[0xDC05]) {memory[0xDC04]=0x24; memory[0xDC05]=0x40;}
        frame_sampleperiod = (memory[0xDC04]+memory[0xDC05]*256)/clock_ratio;
    } else {
        frame_sampleperiod = samplerate/PAL_FRAMERATE;
    }
    if(playaddf==0) { playaddr = ((memory[1]&3)<2)? memory[0xFFFE]+memory[0xFFFF]*256 : memory[0x314]+memory[0x315]*256; }
    else { playaddr=playaddf; if (playaddr>=0xE000 && memory[1]==0x37) memory[1]=0x35; }
    initCPU(playaddr); framecnt=1; finished=0; CPUtime=0;

    return 0;
}

void sid_generate(short *buffer, int samples)
{
    int i, j, output;
    float average;
    for (i = 0; i < samples; i++) {
        framecnt--;
        if (framecnt <= 0) { framecnt = frame_sampleperiod; finished = 0; PC = playaddr; SP = 0xFF; }
        average = 0.0;
        for (j = 0; j < sampleratio; j++) {
            if (finished == 0 && --cycles <= 0) {
                pPC = PC;
                if (CPU() >= 0xFE || ((memory[1]&3) > 1 && pPC < 0xE000 && (PC == 0xEA31 || PC == 0xEA81))) finished = 1;
                if ((addr == 0xDC05 || addr == 0xDC04) && (memory[1]&3) && timermode[subtune]) {
                    frame_sampleperiod = (memory[0xDC04] + memory[0xDC05]*256) / clock_ratio;
                }
                if (storadd >= 0xD420 && storadd < 0xD800 && (memory[1]&3)) {
                    if (!(SID_address[1]<=storadd && storadd<SID_address[1]+0x1F) && !(SID_address[2]<=storadd && storadd<SID_address[2]+0x1F))
                        memory[storadd&0xD41F] = memory[storadd];
                }
            }
            average += SID(0, 0xD400);
            if (SIDamount >= 2) average += SID(1, SID_address[1]);
            if (SIDamount == 3) average += SID(2, SID_address[2]);
        }
        output = average / sampleratio;
        if (output > 32767) output = 32767;
        if (output < -32768) output = -32768;
        buffer[i] = (short)output;
    }
}

void sid_skip_frames(int frames)
{
    int i;
    for (i = 0; i < frames; i++) {
        // Run one frame of CPU (same as what happens per frame in sid_generate)
        finished = 0;
        PC = playaddr;
        SP = 0xFF;
        long int timeout;
        for (timeout = 20000; timeout >= 0; timeout--) {
            if (finished) break;
            if (--cycles <= 0) {
                pPC = PC;
                if (CPU() >= 0xFE || ((memory[1]&3) > 1 && pPC < 0xE000 && (PC == 0xEA31 || PC == 0xEA81))) finished = 1;
                if ((addr == 0xDC05 || addr == 0xDC04) && (memory[1]&3) && timermode[subtune]) {
                    frame_sampleperiod = (memory[0xDC04] + memory[0xDC05]*256) / clock_ratio;
                }
                if (storadd >= 0xD420 && storadd < 0xD800 && (memory[1]&3)) {
                    if (!(SID_address[1]<=storadd && storadd<SID_address[1]+0x1F) && !(SID_address[2]<=storadd && storadd<SID_address[2]+0x1F))
                        memory[storadd&0xD41F] = memory[storadd];
                }
            }
        }
    }
    // Reset frame counter so next sid_generate starts clean
    framecnt = 1;
}

const char* sid_title(void) { return (const char*)SIDtitle_buf; }
const char* sid_author(void) { return (const char*)SIDauthor_buf; }
const char* sid_info(void) { return (const char*)SIDinfo_buf; }
int sid_subtune_count(void) { return subtune_amount; }
