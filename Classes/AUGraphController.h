/*
        File: AUGraphController.h
    Abstract: Demonstrates using the AUTimePitch.
     Version: 1.0.1
    
    Disclaimer: IMPORTANT:  This Apple software is supplied to you by Apple
    Inc. ("Apple") in consideration of your agreement to the following
    terms, and your use, installation, modification or redistribution of
    this Apple software constitutes acceptance of these terms.  If you do
    not agree with these terms, please do not use, install, modify or
    redistribute this Apple software.
    
    In consideration of your agreement to abide by the following terms, and
    subject to these terms, Apple grants you a personal, non-exclusive
    license, under Apple's copyrights in this original Apple software (the
    "Apple Software"), to use, reproduce, modify and redistribute the Apple
    Software, with or without modifications, in source and/or binary forms;
    provided that if you redistribute the Apple Software in its entirety and
    without modifications, you must retain this notice and the following
    text and disclaimers in all such redistributions of the Apple Software.
    Neither the name, trademarks, service marks or logos of Apple Inc. may
    be used to endorse or promote products derived from the Apple Software
    without specific prior written permission from Apple.  Except as
    expressly stated in this notice, no other rights or licenses, express or
    implied, are granted by Apple herein, including but not limited to any
    patent rights that may be infringed by your derivative works or by other
    works in which the Apple Software may be incorporated.
    
    The Apple Software is provided by Apple on an "AS IS" basis.  APPLE
    MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION
    THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS
    FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND
    OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS.
    
    IN NO EVENT SHALL APPLE BE LIABLE FOR ANY SPECIAL, INDIRECT, INCIDENTAL
    OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
    SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
    INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION,
    MODIFICATION AND/OR DISTRIBUTION OF THE APPLE SOFTWARE, HOWEVER CAUSED
    AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE),
    STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE
    POSSIBILITY OF SUCH DAMAGE.
    
    Copyright (C) 2012 Apple Inc. All Rights Reserved.
    
*/

#import <CoreFoundation/CoreFoundation.h>

#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>

#include "CAStreamBasicDescription.h"
#include "CAComponentDescription.h"

#include "lo.h"

#define MAXBUFS  1
#define NUMFILES 1
#define MAXTIMES 360
#define MAXSNDS  3
#define BIN      4
#define MAXSZKS  50
#define WN       MAXSZKS-1
#define METRO    MAXSZKS

#define checkErr( err) \
if(err) {\
OSStatus error = static_cast<OSStatus>(err);\
fprintf(stdout, "CAPlayThrough Error: %ld ->  %s:  %d\n",  (long)error,\
__FILE__, \
__LINE__\
);\
fflush(stdout);\
return err; \
} 

typedef struct {
	UInt32 numFrames;
    AudioStreamBasicDescription asbd;
    AudioSampleType *data;
} SoundBuffer, *SoundBufferPtr;

typedef struct {
    UInt32      maxNumFrames;
    SoundBuffer soundBuffer[MAXBUFS];
} SourceAudioBufferData, *SourceAudioBufferDataPtr;

typedef struct {
    SInt32  angle;
    UInt32  area;
    UInt32  color[3];//[0]:R, [1]:G, [2]:B
    SInt32  distance;
    UInt32  frameNum;
    SInt32  ID;
    UInt32  note;
    UInt32  isAlive;
    SourceAudioBufferDataPtr    sound;
    SInt32                      sn;
} Shizuku;

typedef struct {
    UInt32  resolution;
    UInt64  cnt;
} TimerInfo;

@interface AUGraphController : NSObject
{
    CFURLRef sourceURL;
    
	AUGraph   mGraph;
    AudioUnit mTimeAU[MAXSZKS];
	AudioUnit mMixer;
    AudioUnit filterAU[MAXSZKS];
    AudioUnit vari_metroAU;
    AudioUnit reverbAU;

    
    CAStreamBasicDescription mClientFormat;
    CAStreamBasicDescription mOutputFormat;
    
    SourceAudioBufferData mUserData[MAXSNDS][BIN];
    SourceAudioBufferData metro;
    SourceAudioBufferData wn;

    AudioBufferList *mInputBuffer;
    UInt32 time, numShizuku, binCnt[BIN], IDCnt;
    UInt64 cnt;
    UInt32 resolution;
    BOOL    metroON;
    Shizuku shizuku[MAXSZKS];
    Shizuku s_metro, s_wn;
    lo_server_thread    st;
}

- (void)initializeAUGraph:(Float64)inSampleRate;

- (void)enableInput:(UInt32)inputNum isOn:(AudioUnitParameterValue)isONValue;
- (void)setInputVolume:(UInt32)inputNum value:(AudioUnitParameterValue)value;
- (void)setOutputVolume:(AudioUnitParameterValue)value;
- (void)setTimeRate:(UInt32)inputNum value:(AudioUnitParameterValue)value;
- (Float32)getMeterLevel;
- (void)runAUGraph;
- (void)timer:(UInt64)sampleTime;
- (void)setUplo;
- (void)toggleMetro;
- (void)toggleWN;
- (void)setRGB:(UInt32)n;
- (void)setR:(AudioUnitParameterValue)n;
- (void)setG:(AudioUnitParameterValue)n;
- (void)setB:(AudioUnitParameterValue)n;
- (void)setAngle:(UInt32)n;
- (void)setArea:(UInt32)n;
- (void)setReverb:(AudioUnitParameterValue)n;
@end