#ifndef SID_ENGINE_H
#define SID_ENGINE_H

typedef unsigned char byte;

void cSID_init(int samplerate);
void initSID(void);
void initCPU(unsigned int mempos);
byte CPU(void);
int SID(char num, unsigned int baseaddr);
unsigned int combinedWF(char num, char channel, unsigned int* wfarray, int index, char differ6581);
void createCombinedWF(unsigned int* wfarray, float bitmul, float bitstrength, float treshold);

// Load SID file into memory, return 0 on success
int sid_load(const byte *data, int datalen, int subtune_num);
// Generate audio samples (signed 16-bit mono)
void sid_generate(short *buffer, int samples);
// Get metadata
const char* sid_title(void);
const char* sid_author(void);
const char* sid_info(void);
int sid_subtune_count(void);
// Fast-forward: skip N frames without generating audio (much faster than sid_generate)
void sid_skip_frames(int frames);

#endif
