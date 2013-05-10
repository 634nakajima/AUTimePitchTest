/*
        File: AUGraphController.mm
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

#import "AUGraphController.h"

#pragma mark- Render

static OSStatus renderNotify(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData)
{
    AUGraphController *augc = (AUGraphController *)inRefCon;
    
    if (*ioActionFlags == kAudioUnitRenderAction_PostRender) {
        [augc timer:(UInt64)inTimeStamp->mSampleTime];
    }
    return noErr;
}

// render some silence
static void SilenceData(AudioBufferList *inData)
{
	for (UInt32 i=0; i < inData->mNumberBuffers; i++)
		memset(inData->mBuffers[i].mData, 0, inData->mBuffers[i].mDataByteSize);
}

// audio render procedure to render our client data format
// 2 ch interleaved 'lpcm' platform Canonical format - this is the mClientFormat data, see CAStreamBasicDescription SetCanonical()
// note that this format can differ between platforms so be sure of the data type you're working with,
// for example AudioSampleType may be Float32 or may be SInt16
static OSStatus renderInput(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData)
{
    Shizuku *shizuku = (Shizuku *)inRefCon;

    if (shizuku->note && shizuku->sound) {
        //NSLog(@"shizuku:%d",shizuku->distance);

        AudioSampleType *in = shizuku->sound->soundBuffer[inBusNumber].data;
        AudioSampleType *out = (AudioSampleType *)ioData->mBuffers[0].mData;
    
        UInt32 sample = shizuku->frameNum * shizuku->sound->soundBuffer[inBusNumber].asbd.mChannelsPerFrame;
    
        // make sure we don't attempt to render more data than we have available in the source buffer
        if ((shizuku->frameNum + inNumberFrames) > shizuku->sound->soundBuffer[inBusNumber].numFrames) {
            UInt32 offset = (shizuku->frameNum + inNumberFrames) - shizuku->sound->soundBuffer[inBusNumber].numFrames;
            if (offset < inNumberFrames) {
                // copy the last bit of source
                SilenceData(ioData);
                memcpy(out, &in[sample], ((inNumberFrames - offset) * shizuku->sound->soundBuffer[inBusNumber].asbd.mBytesPerFrame));
            }
        } else {
            memcpy(out, &in[sample], ioData->mBuffers[0].mDataByteSize);
        }

        // in the iPhone sample using the iPodEQ, a graph notification was used to count rendered source samples at output to know when to loop the source
        // because there is time compression/expansion AU being used in this sample as well as rate conversion, you can't really use a render notification
        // on the output of the graph since you can't assume the graph is producing output at the same rate that it is consuming input
        // therefore, this kind of sample counting needs to happen somewhere upstream of the timepich AU and in this case the AUConverter
        // ** doing it here is the place for it **
        shizuku->frameNum += inNumberFrames;
        if (shizuku->frameNum >= shizuku->sound->maxNumFrames) {
            shizuku->frameNum = 0;
            shizuku->note = 0;
        }
    } else {
        SilenceData(ioData);
    }
    //printf("render input bus %u sample %u\n", inBusNumber, sample);
    
    return noErr;
}

#pragma mark- AUGraphController

@interface AUGraphController (hidden)
 
- (void)loadSpeechTrack:(Float64)inGraphSampleRate;
 
@end

@implementation AUGraphController

- (void)dealloc
{    
    printf("AUGraphController dealloc\n");
    
    DisposeAUGraph(mGraph);
    
    free(mUserData[0].soundBuffer[0].data);
    
    CFRelease(sourceURL);
    
	[super dealloc];
}

- (void)awakeFromNib
{
    for(int i=0; i<MAXSZKS; i++) {
        shizuku[i].angle = 0;
        shizuku[i].area = 0;
        shizuku[i].color[0] = 0;
        shizuku[i].color[1] = 0;
        shizuku[i].color[2] = 0;
        shizuku[i].distance = 7*i;
        shizuku[i].frameNum = 0;
        shizuku[i].ID = i;
        shizuku[i].note = 0;
        shizuku[i].sound = NULL;
    }
    time = 0;
    numShizuku = 0;//MAXSZKS;
    resolution = 441*2;
    cnt = 1;
    
    printf("AUGraphController awakeFromNib\n");
    
    // clear the mSoundBuffer struct
	memset(&mUserData[0].soundBuffer, 0, sizeof(mUserData[0].soundBuffer));
    
    // create the URL we'll use for source
    
    // AAC demo track


    [self setUplo];
}

- (void)initializeAUGraph:(Float64)inSampleRate
{
    printf("initializeAUGraph\n");
    
    AUNode outputNode;
    AUNode timePitchNode[MAXSZKS];
	AUNode mixerNode;
    AUNode converterNode[MAXSZKS];
    AudioUnit converterAU[MAXSZKS];
    AUNode filterNode[MAXSZKS];
    AudioUnit filterAU[MAXSZKS];

    printf("create client format ASBD\n");
    
    // client format audio going into the converter
    mClientFormat.SetCanonical(2, true);						
    mClientFormat.mSampleRate = 44100.0; // arbitrary sample rate chosen to demonstrate working with 3 different sample rates
                                         // 1) the rate passed in which ends up being the the graph rate (in this sample the arbitrary choice of 11KHz)
                                         // 2) the rate of the original file which in this case is 44.1kHz (rate conversion to client format of 22k is done by ExtAudioFile)
                                         // 3) the rate we want for our source data which in this case is 22khz (AUConverter taking care of conversion to Graph Rate)
                                         // File @ 44.1kHz - > ExtAudioFile - > Client Format @ 22kHz - > AUConverter graph @ 11kHz -> Output
                                         // while this type of multiple rate conversions isn't what you'd probably want to do in your application, this sample simply demonstrates
                                         // this flexibility -- where you perform rate conversions is important and some thought should be put into the decision
    mClientFormat.Print();
    
    printf("create output format ASBD\n");
    
    // output format
    mOutputFormat.SetAUCanonical(2, false);
	mOutputFormat.mSampleRate = inSampleRate;
    mOutputFormat.Print();
	
	OSStatus result = noErr;
    
    // load up the demo audio data
    //[self loadSpeechTrack: inSampleRate];
    //[self SetupAUHAL];
    printf("-----------\n");
    printf("new AUGraph\n");
    
    // create a new AUGraph
	result = NewAUGraph(&mGraph);
    if (result) { printf("NewAUGraph result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
	
    // create four CAComponentDescription for the AUs we want in the graph
    
    // output unit
    CAComponentDescription output_desc(kAudioUnitType_Output, kAudioUnitSubType_DefaultOutput, kAudioUnitManufacturer_Apple);
    
    // timePitchNode unit
    CAComponentDescription timePitch_desc(kAudioUnitType_FormatConverter, kAudioUnitSubType_Varispeed, kAudioUnitManufacturer_Apple);
    
    // multichannel mixer unit
	CAComponentDescription mixer_desc(kAudioUnitType_Mixer, kAudioUnitSubType_MultiChannelMixer, kAudioUnitManufacturer_Apple);
    
    // AU Converter
    CAComponentDescription converter_desc(kAudioUnitType_FormatConverter, kAudioUnitSubType_AUConverter, kAudioUnitManufacturer_Apple);
    
    CAComponentDescription filter_desc(kAudioUnitType_Effect, kAudioUnitSubType_LowPassFilter, kAudioUnitManufacturer_Apple);

    
    printf("add nodes\n");

    // create a node in the graph that is an AudioUnit, using the supplied component description to find and open that unit
	result = AUGraphAddNode(mGraph, &output_desc, &outputNode);
	if (result) { printf("AUGraphNewNode 1 result %lu %4.4s\n", (unsigned long)result, (char *)&result); return; }

	result = AUGraphAddNode(mGraph, &mixer_desc, &mixerNode);
	if (result) { printf("AUGraphNewNode 3 result %lu %4.4s\n", (unsigned long)result, (char*)&result); return; }
    
    // connect a node's output to a node's input
    // au converter -> mixer -> timepitch -> output
    
    for (int i=0; i<MAXSZKS; i++) {
        
        result = AUGraphAddNode(mGraph, &timePitch_desc, &timePitchNode[i]);
        if (result) { printf("AUGraphNewNode 2 result %lu %4.4s\n", (unsigned long)result, (char*)&result); return; }
        
        result = AUGraphAddNode(mGraph, &converter_desc, &converterNode[i]);
        if (result) { printf("AUGraphNewNode 3 result %lu %4.4s\n", (unsigned long)result, (char*)&result); return; }
        
        result = AUGraphAddNode(mGraph, &filter_desc, &filterNode[i]);
        if (result) { printf("AUGraphNewNode 3 result %lu %4.4s\n", (unsigned long)result, (char*)&result); return; }
        
        result = AUGraphConnectNodeInput(mGraph, converterNode[i], 0, timePitchNode[i], 0);
        if (result) { printf("AUGraphConnectNodeInput1 result %lu %4.4s %d\n", (unsigned long)result, (char*)&result, i); return; }
    
        result = AUGraphConnectNodeInput(mGraph, timePitchNode[i], 0, filterNode[i], 0);
        if (result) { printf("AUGraphConnectNodeInput1 result %lu %4.4s %d\n", (unsigned long)result, (char*)&result, i); return; }
        
        result = AUGraphConnectNodeInput(mGraph, filterNode[i], 0, mixerNode, i);
        if (result) { printf("AUGraphConnectNodeInput2 result %lu %4.4s %d\n", (unsigned long)result, (char*)&result, i); return; }
    }
   
    result = AUGraphConnectNodeInput(mGraph, mixerNode, 0, outputNode, 0);
    if (result) { printf("AUGraphConnectNodeInput result %lu %4.4s\n", (unsigned long)result, (char*)&result); return; }
    
    // open the graph -- AudioUnits are open but not initialized (no resource allocation occurs here)
	result = AUGraphOpen(mGraph);
	if (result) { printf("AUGraphOpen result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
	
    // grab audio unit instances from the nodes

    for (int i=0; i<MAXSZKS; i++) {
        result = AUGraphNodeInfo(mGraph, converterNode[i], NULL, &converterAU[i]);
        if (result) { printf("AUGraphConnectNodeInput3 result %lu %4.4s %d\n", (unsigned long)result, (char*)&result, i); return; }
        
        result = AUGraphNodeInfo(mGraph, timePitchNode[i], NULL, &mTimeAU[i]);
        if (result) { printf("AUGraphConnectNodeInput4 result %lu %4.4s %d\n", (unsigned long)result, (char*)&result, i); return; }
        
        result = AUGraphNodeInfo(mGraph, filterNode[i], NULL, &filterAU[i]);
        if (result) { printf("AUGraphConnectNodeInput3 result %lu %4.4s %d\n", (unsigned long)result, (char*)&result, i); return; }
    }
    
	result = AUGraphNodeInfo(mGraph, mixerNode, NULL, &mMixer);
    if (result) { printf("AUGraphNodeInfo result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
    
    // set bus count
	UInt32 numbuses = MAXSZKS;
	
    printf("set input bus count %lu\n", (unsigned long)numbuses);
	
    result = AudioUnitSetProperty(mMixer, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &numbuses, sizeof(numbuses));
    if (result) { printf("AudioUnitSetProperty result1 %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
    
    // enable metering
    UInt32 onValue = 1;
    
    printf("enable metering for input bus 0\n");
    
    result = AudioUnitSetProperty(mMixer, kAudioUnitProperty_MeteringMode, kAudioUnitScope_Input, 0, &onValue, sizeof(onValue));
    if (result) { printf("AudioUnitSetProperty result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
    
    for (int i=0; i<MAXSZKS; i++) {
        // setup render callback struct
        AURenderCallbackStruct rcbs;
        rcbs.inputProc = &renderInput;
        rcbs.inputProcRefCon = &shizuku[i];
    
        printf("set AUGraphSetNodeInputCallback\n");
    
        // set a callback for the specified node's specified input bus (bus 1)
        result = AUGraphSetNodeInputCallback(mGraph, converterNode[i], 0, &rcbs);
        if (result) { printf("AUGraphSetNodeInputCallback result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
    }
    
    result = AUGraphAddRenderNotify(mGraph, renderNotify, self);
    if (result) { printf("AUGraphSetNodeInputCallback result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }

    
    printf("set converter input bus %d client kAudioUnitProperty_StreamFormat\n", 0);
    
    for (int i=0; i<MAXSZKS; i++) {

        // set the input stream format, this is the format of the audio for the converter input bus (bus 1)
        result = AudioUnitSetProperty(converterAU[i], kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &mClientFormat, sizeof(mClientFormat));
        if (result) { printf("AudioUnitSetProperty result %ld %08X %4.4s %d\n", (long)result, (unsigned int)result, (char*)&result, i); return; }
    
        // in an au graph, each nodes output stream format (including sample rate) needs to be set explicitly
        // this stream format is propagated to its destination's input stream format
    
        printf("set converter output kAudioUnitProperty_StreamFormat\n");
    
        // set the output stream format of the converter
        result = AudioUnitSetProperty(converterAU[i], kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &mOutputFormat, sizeof(mOutputFormat));
        if (result) { printf("AudioUnitSetProperty result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }

        // set the output stream format of the converter
        result = AudioUnitSetProperty(filterAU[i], kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &mOutputFormat, sizeof(mOutputFormat));
        if (result) { printf("AudioUnitSetProperty result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
        
        printf("set mixer output kAudioUnitProperty_StreamFormat\n");
        
        // set the output stream format of the timepitch unit
        result = AudioUnitSetProperty(mTimeAU[i], kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &mOutputFormat, sizeof(mOutputFormat));
        if (result) { printf("AudioUnitSetProperty1 result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }

        [self enableInput:i isOn:1.0];
        [self setInputVolume:i value:0.5];
        [self setTimeRate:i value:-600+50*i];
        
        result = AudioUnitSetParameter(filterAU[i], kLowPassParam_CutoffFrequency, kAudioUnitScope_Global, 0, 15000 - 200*i, 0);
        if (result) { printf("AudioUnitSetParameter kTimePitchParam_Rate Global result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
    }

    // set the output stream format of the mixer
    result = AudioUnitSetProperty(mMixer, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &mOutputFormat, sizeof(mOutputFormat));
    if (result) { printf("AudioUnitSetProperty result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
    
    result = AudioUnitSetProperty(mInputUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &mOutputFormat, sizeof(mOutputFormat));
    //printf("set timepitch output kAudioUnitProperty_StreamFormat\n");
    

    //}
    printf("AUGraphInitialize\n");
								
    // now that we've set everything up we can initialize the graph, this will also validate the connections
	result = AUGraphInitialize(mGraph);
    if (result) { printf("AUGraphInitialize result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
    
    CAShow(mGraph);
    

}

// load up audio data from the demo file into mSoundBuffer.data which is then used in the render proc as the source data to render
- (void)loadSpeechTrack:(Float64)inGraphSampleRate kobin:(UInt32)kID
{
    mUserData[kID].maxNumFrames = 0;
        
    printf("loadSpeechTrack, %d\n", 1);
    
    ExtAudioFileRef xafref = 0;
    NSString *source;
    switch (kID) {
        case 1:
            source = [[NSBundle mainBundle] pathForResource:@"Kobin1" ofType:@"aif"];
            break;
            
        case 2:
            source = [[NSBundle mainBundle] pathForResource:@"Kobin2" ofType:@"aif"];
            break;

        case 3:
            source = [[NSBundle mainBundle] pathForResource:@"Kobin3" ofType:@"aif"];
            break;

        case 4:
            source = [[NSBundle mainBundle] pathForResource:@"Kobin4" ofType:@"aif"];
            break;
            
        default:
            return;
            break;
    }

    sourceURL[kID] = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, (CFStringRef)source, kCFURLPOSIXPathStyle, false);
    
    // open one of the two source files
    OSStatus result = ExtAudioFileOpenURL(sourceURL[kID], &xafref);
    if (result || !xafref) { printf("ExtAudioFileOpenURL result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
    
    // get the file data format, this represents the file's actual data format, we need to know the actual source sample rate
    // note that the client format set on ExtAudioFile is the format of the date we really want back
    CAStreamBasicDescription fileFormat;
    UInt32 propSize = sizeof(fileFormat);
    
    result = ExtAudioFileGetProperty(xafref, kExtAudioFileProperty_FileDataFormat, &propSize, &fileFormat);
    if (result) { printf("ExtAudioFileGetProperty kExtAudioFileProperty_FileDataFormat result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
    
    printf("file %d, native file format\n", 1);
    fileFormat.Print();
        
    // get the file's length in sample frames
    UInt64 numFrames = 0;
    propSize = sizeof(numFrames);
    result = ExtAudioFileGetProperty(xafref, kExtAudioFileProperty_FileLengthFrames, &propSize, &numFrames);
    if (result) { printf("ExtAudioFileGetProperty kExtAudioFileProperty_FileLengthFrames result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
    
    // account for any sample rate conversion between the file and client sample rates
    double rateRatio = mClientFormat.mSampleRate / fileFormat.mSampleRate;
    numFrames *= rateRatio;
    
    // set the client format to be what we want back -- this is the same format audio we're giving to the input callback
    result = ExtAudioFileSetProperty(xafref, kExtAudioFileProperty_ClientDataFormat, sizeof(mClientFormat), &mClientFormat);
    if (result) { printf("ExtAudioFileSetProperty kExtAudioFileProperty_ClientDataFormat %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }

    // set up and allocate memory for the source buffer
    mUserData[kID].soundBuffer[0].numFrames = numFrames;
    mUserData[kID].soundBuffer[0].asbd = mClientFormat;

    UInt32 samples = numFrames * mUserData[0].soundBuffer[0].asbd.mChannelsPerFrame;
    mUserData[kID].soundBuffer[0].data = (AudioSampleType *)calloc(samples, sizeof(AudioSampleType));
    
    // set up a AudioBufferList to read data into
    AudioBufferList bufList;
    bufList.mNumberBuffers = 1;
    bufList.mBuffers[0].mNumberChannels = mUserData[kID].soundBuffer[0].asbd.mChannelsPerFrame;
    bufList.mBuffers[0].mData = mUserData[kID].soundBuffer[0].data;
    bufList.mBuffers[0].mDataByteSize = samples * sizeof(AudioSampleType);

    // perform a synchronous sequential read of the audio data out of the file into our allocated data buffer
    UInt32 numPackets = numFrames;
    result = ExtAudioFileRead(xafref, &numPackets, &bufList);
    if (result) {
        printf("ExtAudioFileRead result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); 
        free(mUserData[kID].soundBuffer[0].data);
        mUserData[kID].soundBuffer[0].data = 0;
        return;
    }
    
    // update after the read to reflect the real number of frames read into the buffer
    // note that ExtAudioFile will automatically trim the 2112 priming frames off the AAC demo source
    mUserData[kID].soundBuffer[0].numFrames = numPackets;
    
    // maxNumFrames is used to know when we need to loop the source
    mUserData[kID].maxNumFrames = mUserData[kID].soundBuffer[0].numFrames;
    
    // close the file and dispose the ExtAudioFileRef
    ExtAudioFileDispose(xafref);
    
}

#pragma mark-

// enable or disables a specific bus
- (void)enableInput:(UInt32)inputNum isOn:(AudioUnitParameterValue)isONValue
{
    printf("BUS %ld isON %f\n", (long)inputNum, isONValue);
         
    OSStatus result = AudioUnitSetParameter(mMixer, kMultiChannelMixerParam_Enable, kAudioUnitScope_Input, inputNum, isONValue, 0);
    if (result) { printf("AudioUnitSetParameter kMultiChannelMixerParam_Enable result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }

}

// sets the input volume for a specific bus
- (void)setInputVolume:(UInt32)inputNum value:(AudioUnitParameterValue)value
{
    printf("BUS %ld volume %f\n", (long)inputNum, value);
    
	OSStatus result = AudioUnitSetParameter(mMixer, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, inputNum, value, 0);
    if (result) { printf("AudioUnitSetParameter kMultiChannelMixerParam_Volume Input result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
}

// sets the overall mixer output volume
- (void)setOutputVolume:(AudioUnitParameterValue)value
{
    printf("Output volume %f\n", value);
        
	OSStatus result = AudioUnitSetParameter(mMixer, kMultiChannelMixerParam_Volume, kAudioUnitScope_Output, 0, value, 0);
    if (result) { printf("AudioUnitSetParameter kMultiChannelMixerParam_Volume Output result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
}

// sets the rate of the timepitch Audio Unit
- (void)setTimeRate:(UInt32)inputNum value:(AudioUnitParameterValue)value
{
    printf("Set rate %f\n", value);
    
    OSStatus result = AudioUnitSetParameter(mTimeAU[inputNum], kVarispeedParam_PlaybackCents, kAudioUnitScope_Global, 0, value, 0);
    if (result) { printf("AudioUnitSetParameter kTimePitchParam_Rate Global result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
}

// return the levels from the multichannel mixer
- (Float32)getMeterLevel
{
    Float32 value = -120.0;
    
    OSStatus result = AudioUnitGetParameter(mMixer, kMultiChannelMixerParam_PostAveragePower, kAudioUnitScope_Output, 0, &value);
    if (result) { printf("AudioUnitGetParameter kMultiChannelMixerParam_PostAveragePower Input result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); }
    
    return value;
}

// start or stop graph
- (void)runAUGraph
{
    Boolean isRunning = false;
    
    OSStatus result = AUGraphIsRunning(mGraph, &isRunning);
    if (result) { printf("AUGraphIsRunning result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
    
    if (isRunning) {
        printf("STOP\n");
        
        result = AUGraphStop(mGraph);
        if (result) { printf("AUGraphStop result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
    } else {
        printf("PLAY\n");
    
        result = AUGraphStart(mGraph);
        if (result) { printf("AUGraphStart result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
    }
}

- (void)timer:(UInt64)sampleTime
{
    if (sampleTime > resolution*cnt) {
        cnt++;
        if(time++ == MAXTIMES) time = 0;
    
        for (UInt32 i=0; i<numShizuku; i++) {
            if (shizuku[i].distance == time) {
                shizuku[i].note = 1;
                shizuku[i].frameNum = 0;
                [self setTimeRate:i value:shizuku[i].angle*3];
            }
        }
    }
}

- (void)setUplo
{
    st = lo_server_thread_new("15000", NULL);
    lo_server_thread_add_method(st, "/add", "iiiiiiii", shizuku_add, self);
    lo_server_thread_add_method(st, "/delete", "iiiiiiii", shizuku_delete, self);
    lo_server_thread_add_method(st, "/user", "iii", user_handler, self);
    lo_server_thread_add_method(st, "/routo", "ii", routo_handler, self);
    lo_server_thread_start(st);
}

int shizuku_add(const char *path, const char *types, lo_arg **argv, int argc,
                void *data, void *user_data)
{
    NSLog(@"add!");
    AUGraphController   *augc = (AUGraphController *)user_data;
    
    augc->shizuku[augc->numShizuku].ID          = argv[0]->i;
    augc->shizuku[augc->numShizuku].sound       = &(augc->mUserData[argv[1]->i - 1]);
    augc->shizuku[augc->numShizuku].distance    = argv[2]->i;
    augc->shizuku[augc->numShizuku].area        = argv[3]->i;
    augc->shizuku[augc->numShizuku].angle       = argv[4]->i;
    augc->shizuku[augc->numShizuku].color[0]    = argv[5]->i;
    augc->shizuku[augc->numShizuku].color[1]    = argv[6]->i;
    augc->shizuku[augc->numShizuku].color[2]    = argv[7]->i;
    
    if (augc->numShizuku++ == 64) augc->numShizuku = 0;
    return 0;
}

int shizuku_delete(const char *path, const char *types, lo_arg **argv, int argc,
                   void *data, void *user_data)
{
    NSLog(@"delete!");
    AUGraphController   *augc = (AUGraphController *)user_data;
    
    for (UInt32 i=0; i<augc->numShizuku; i++) {
        if ((int)augc->shizuku[i].ID == argv[0]->i) { 
            UInt32 j;
            for (j=i; j<augc->numShizuku-1; j++) {
                augc->shizuku[j].angle =augc->shizuku[j+1].angle;
                augc->shizuku[j].area =augc->shizuku[j+1].area;
                augc->shizuku[j].color[0] = augc->shizuku[j+1].color[0];
                augc->shizuku[j].color[1] = augc->shizuku[j+1].color[1];
                augc->shizuku[j].color[2] = augc->shizuku[j+1].color[2];
                augc->shizuku[j].distance = augc->shizuku[j+1].distance;
                augc->shizuku[j].frameNum = augc->shizuku[j+1].frameNum;
                augc->shizuku[j].ID = augc->shizuku[j+1].ID;
                augc->shizuku[j].note = augc->shizuku[j+1].note;
                augc->shizuku[j].sound = augc->shizuku[j+1].sound;
            }
            augc->shizuku[j].angle = 0;
            augc->shizuku[j].area = 0;
            augc->shizuku[j].color[0] = 0;
            augc->shizuku[j].color[1] = 0;
            augc->shizuku[j].color[2] = 0;
            augc->shizuku[j].distance = -1;
            augc->shizuku[j].frameNum = 0;
            augc->shizuku[j].ID = 0;
            augc->shizuku[j].note = 0;
            augc->shizuku[j].sound = NULL;
        }
    }
    return 0;
}

int user_handler(const char *path, const char *types, lo_arg **argv, int argc,
                  void *data, void *user_data)
{
    
    return 0;
}

int routo_handler(const char *path, const char *types, lo_arg **argv, int argc,
                 void *data, void *user_data)
{
    AUGraphController *augc = (AUGraphController *)user_data;
    [augc loadSpeechTrack:44100.0 kobin:argv[0]->i];
    return 0;
}
/*
-(OSStatus) SetupAUHAL
{
	OSStatus err = noErr;
    
    AudioComponent comp;
    AudioComponentDescription desc;
	
	//There are several different types of Audio Units.
	//Some audio units serve as Outputs, Mixers, or DSP
	//units. See AUComponent.h for listing
	desc.componentType = kAudioUnitType_Output;
	
	//Every Component has a subType, which will give a clearer picture
	//of what this components function will be.
	desc.componentSubType = kAudioUnitSubType_HALOutput;
	
	//all Audio Units in AUComponent.h must use 
	//"kAudioUnitManufacturer_Apple" as the Manufacturer
	desc.componentManufacturer = kAudioUnitManufacturer_Apple;
	desc.componentFlags = 0;
	desc.componentFlagsMask = 0;
	
	//Finds a component that meets the desc spec's
    comp = AudioComponentFindNext(NULL, &desc);
	if (comp == NULL) exit (-1);
	
	//gains access to the services provided by the component
    err = AudioComponentInstanceNew(comp, &mInputUnit);
    checkErr(err);
    
	//AUHAL needs to be initialized before anything is done to it
	err = AudioUnitInitialize(mInputUnit);
	checkErr(err);
	
	err = [self EnableIO];
	checkErr(err);
	
	err = [self CallbackSetup];
	checkErr(err);
	
	//Don't setup buffers until you know what the 
	//input and output device audio streams look like.
    
	err = AudioUnitInitialize(mInputUnit);
    
	return err;
}

-(OSStatus) EnableIO
{	
	OSStatus err = noErr;
	UInt32 enableIO;
	
	///////////////
	//ENABLE IO (INPUT)
	//You must enable the Audio Unit (AUHAL) for input and disable output 
	//BEFORE setting the AUHAL's current device.
	
	//Enable input on the AUHAL
	enableIO = 1;
	err =  AudioUnitSetProperty(mInputUnit,
								kAudioOutputUnitProperty_EnableIO,
								kAudioUnitScope_Input,
								1, // input element
								&enableIO,
								sizeof(enableIO));
	checkErr(err);
	
	//disable Output on the AUHAL
	enableIO = 0;
	err = AudioUnitSetProperty(mInputUnit,
                               kAudioOutputUnitProperty_EnableIO,
                               kAudioUnitScope_Output,
                               0,   //output element
                               &enableIO,
                               sizeof(enableIO));
	return err;
}

static OSStatus InputProc(void *inRefCon,
                          AudioUnitRenderActionFlags *ioActionFlags,
                          const AudioTimeStamp *inTimeStamp,
                          UInt32 inBusNumber,
                          UInt32 inNumberFrames,
                          AudioBufferList * ioData)
{
    OSStatus err = noErr;
    AUGraphController *augc = (AUGraphController *)inRefCon;
	//Get the new audio data
	err = AudioUnitRender(augc->mInputUnit,
                          ioActionFlags,
                          inTimeStamp, 
                          inBusNumber,     
                          inNumberFrames, //# of frames requested
                          augc->mInputBuffer);// Audio Buffer List to hold data
	checkErr(err);
    
	return err;
}

-(OSStatus) CallbackSetup
{
	OSStatus err = noErr;
    AURenderCallbackStruct input;
	
    input.inputProc = InputProc;
    input.inputProcRefCon = self;
	
	//Setup the input callback. 
	err = AudioUnitSetProperty(mInputUnit, 
                               kAudioOutputUnitProperty_SetInputCallback, 
                               kAudioUnitScope_Global,
                               0,
                               &input, 
                               sizeof(input));
	checkErr(err);
	return err;
}
*/
@end