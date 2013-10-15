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

static OSStatus renderInput(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData)
{
    Shizuku *shizuku = (Shizuku *)inRefCon;

    if (shizuku->note && shizuku->sound) {
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
            shizuku->isAlive = 0;
            if (shizuku->ID != -2) shizuku->note = 0;//WhiteNoise(ID:-2) -> Loop
            
            lo_send(lo_address_new("localhost", "13000"),
                    "/stop",
                    "i",//Drop ID
                    shizuku->ID);
        }
    } else {
        SilenceData(ioData);
    }    
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
    
    // free the mSoundBuffer struct
    for (int i=0; i<BIN; i++) {
        for (int j=0; j<MAXSNDS; j++) {
            if (mUserData[j][i].soundBuffer[0].data != NULL) free(mUserData[j][i].soundBuffer[0].data);
        }
    }

    CFRelease(sourceURL);
    
	[super dealloc];
}

- (void)awakeFromNib
{
}

- (void)initializeAUGraph:(Float64)inSampleRate
{
    printf("initializeAUGraph\n");
    
    AUNode outputNode;
    AUNode mixerNode;
    AUNode timePitchNode[MAXSZKS];
    AUNode converterNode[MAXSZKS];
    AUNode filterNode[MAXSZKS];
    AUNode vari_metroNode;
    AUNode reverbNode;
    AudioUnit converterAU[MAXSZKS];

    AUNode con_metroNode;
    AudioUnit con_metroAU;


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
    
    CAComponentDescription filter_desc(kAudioUnitType_Effect, kAudioUnitSubType_AUFilter, kAudioUnitManufacturer_Apple);

    CAComponentDescription reverb_desc(kAudioUnitType_Effect, kAudioUnitSubType_MatrixReverb, kAudioUnitManufacturer_Apple);

    printf("add nodes\n");

    // create a node in the graph that is an AudioUnit, using the supplied component description to find and open that unit
	result = AUGraphAddNode(mGraph, &output_desc, &outputNode);
	if (result) { printf("AUGraphNewNode 1 result %lu %4.4s\n", (unsigned long)result, (char *)&result); return; }

	result = AUGraphAddNode(mGraph, &mixer_desc, &mixerNode);
	if (result) { printf("AUGraphNewNode 3 result %lu %4.4s\n", (unsigned long)result, (char*)&result); return; }
    
    result = AUGraphAddNode(mGraph, &reverb_desc, &reverbNode);
	if (result) { printf("AUGraphNewNode 3 result %lu %4.4s\n", (unsigned long)result, (char*)&result); return; }

    result = AUGraphAddNode(mGraph, &converter_desc, &con_metroNode);
	if (result) { printf("AUGraphNewNode 3 result %lu %4.4s\n", (unsigned long)result, (char*)&result); return; }
    
    result = AUGraphAddNode(mGraph, &timePitch_desc, &vari_metroNode);
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
   
    result = AUGraphConnectNodeInput(mGraph, mixerNode, 0, reverbNode, 0);
    if (result) { printf("AUGraphConnectNodeInput result %lu %4.4s\n", (unsigned long)result, (char*)&result); return; }
    
    result = AUGraphConnectNodeInput(mGraph, reverbNode, 0, outputNode, 0);
    if (result) { printf("AUGraphConnectNodeInput result %lu %4.4s\n", (unsigned long)result, (char*)&result); return; }

    result = AUGraphConnectNodeInput(mGraph, con_metroNode, 0, vari_metroNode, 0);
    if (result) { printf("AUGraphConnectNodeInput result %lu %4.4s\n", (unsigned long)result, (char*)&result); return; }

    result = AUGraphConnectNodeInput(mGraph, vari_metroNode, 0, mixerNode, MAXSZKS);
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
    
    result = AUGraphNodeInfo(mGraph, reverbNode, NULL, &reverbAU);
    if (result) { printf("AUGraphNodeInfo result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }

    result = AUGraphNodeInfo(mGraph, con_metroNode, NULL, &con_metroAU);
    if (result) { printf("AUGraphNodeInfo result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
    
    result = AUGraphNodeInfo(mGraph, vari_metroNode, NULL, &vari_metroAU);
    if (result) { printf("AUGraphNodeInfo result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
    
    // set bus count
	UInt32 numbuses = MAXSZKS+1;//+1 -> metro
	
    printf("set input bus count %lu\n", (unsigned long)numbuses);
	
    result = AudioUnitSetProperty(mMixer, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &numbuses, sizeof(numbuses));
    if (result) { printf("AudioUnitSetProperty result1 %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
    
    // enable metering
    UInt32 onValue = 1;
    
    printf("enable metering for input bus 0\n");
    
    result = AudioUnitSetProperty(mMixer, kAudioUnitProperty_MeteringMode, kAudioUnitScope_Output, 0, &onValue, sizeof(onValue));
    if (result) { printf("AudioUnitSetProperty result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
    
    for (int i=0; i<WN; i++) {
        // setup render callback struct
        AURenderCallbackStruct rcbs;
        rcbs.inputProc = &renderInput;
        rcbs.inputProcRefCon = &shizuku[i];
    
        printf("set AUGraphSetNodeInputCallback\n");
    
        // set a callback for the specified node's specified input bus (bus 1)
        result = AUGraphSetNodeInputCallback(mGraph, converterNode[i], 0, &rcbs);
        if (result) { printf("AUGraphSetNodeInputCallback result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
    }
    
    AURenderCallbackStruct rcbs;
    rcbs.inputProc = &renderInput;
    rcbs.inputProcRefCon = &s_metro;
    
    printf("set AUGraphSetNodeInputCallback\n");
    
    // set a callback for the specified node's specified input bus (bus 1)
    result = AUGraphSetNodeInputCallback(mGraph, con_metroNode, 0, &rcbs);
    if (result) { printf("AUGraphSetNodeInputCallback result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
    
    result = AUGraphAddRenderNotify(mGraph, renderNotify, self);
    if (result) { printf("AUGraphSetNodeInputCallback result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }

    rcbs.inputProcRefCon = &s_wn;
    
    result = AUGraphSetNodeInputCallback(mGraph, converterNode[WN], 0, &rcbs);
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
        [self setInputVolume:i value:0.8];
    }

    // set the output stream format of the mixer
    result = AudioUnitSetProperty(mMixer, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &mOutputFormat, sizeof(mOutputFormat));
    if (result) { printf("AudioUnitSetProperty result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }

    result = AudioUnitSetProperty(con_metroAU, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &mClientFormat, sizeof(mClientFormat));
    if (result) { printf("AudioUnitSetProperty result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
    
    // set the output stream format of the converter
    result = AudioUnitSetProperty(con_metroAU, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &mOutputFormat, sizeof(mOutputFormat));
    if (result) { printf("AudioUnitSetProperty result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }

    // set the output stream format of the converter
    result = AudioUnitSetProperty(vari_metroAU, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &mOutputFormat, sizeof(mOutputFormat));
    if (result) { printf("AudioUnitSetProperty result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
    
    [self enableInput:METRO isOn:1.0];
    [self setInputVolume:METRO value:0.1];
    
    result = AudioUnitSetParameter(vari_metroAU, kVarispeedParam_PlaybackCents, kAudioUnitScope_Global, 0, 1200, 0);
    if (result) { printf("AudioUnitSetParameter kTimePitchParam_Rate Global result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
    
    //printf("set timepitch output kAudioUnitProperty_StreamFormat\n");
    

    printf("AUGraphInitialize\n");
								
    // now that we've set everything up we can initialize the graph, this will also validate the connections
	result = AUGraphInitialize(mGraph);
    if (result) { printf("AUGraphInitialize result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
    
    CAShow(mGraph);
    [self initShizuku];

}

// load up audio data from the demo file into mSoundBuffer.data which is then used in the render proc as the source data to render
- (void)loadSpeechTrack:(Float64)inGraphSampleRate kobin:(UInt32)kID
{
    mUserData[binCnt[kID]][kID].maxNumFrames = 0;
        
    printf("loadSpeechTrack, %d\n", kID);
    
    ExtAudioFileRef xafref = 0;
    NSString *source;
    switch (kID) {
        case 0:
            source = [[NSBundle mainBundle] pathForResource:@"kobin1" ofType:@"aiff"];
            break;
            
        case 1:
            source = [[NSBundle mainBundle] pathForResource:@"kobin2" ofType:@"aiff"];
            break;

        case 2:
            source = [[NSBundle mainBundle] pathForResource:@"kobin3" ofType:@"aiff"];
            break;

        case 3:
            source = [[NSBundle mainBundle] pathForResource:@"kobin4" ofType:@"aiff"];
            break;
            
        default:
            return;
            break;
    }
    NSLog(@"source:%@",source);
    if(!source) return;

    sourceURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, (CFStringRef)source, kCFURLPOSIXPathStyle, false);
    
    // open one of the two source files
    OSStatus result = ExtAudioFileOpenURL(sourceURL, &xafref);
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
    mUserData[binCnt[kID]][kID].soundBuffer[0].numFrames = numFrames;
    mUserData[binCnt[kID]][kID].soundBuffer[0].asbd = mClientFormat;

    UInt32 samples = numFrames * mUserData[binCnt[kID]][kID].soundBuffer[0].asbd.mChannelsPerFrame;
    if (mUserData[binCnt[kID]][kID].soundBuffer[0].data != NULL) free(mUserData[binCnt[kID]][kID].soundBuffer[0].data);
    mUserData[binCnt[kID]][kID].soundBuffer[0].data = (AudioSampleType *)calloc(samples, sizeof(AudioSampleType));
    
    // set up a AudioBufferList to read data into
    AudioBufferList bufList;
    bufList.mNumberBuffers = 1;
    bufList.mBuffers[0].mNumberChannels = mUserData[binCnt[kID]][kID].soundBuffer[0].asbd.mChannelsPerFrame;
    bufList.mBuffers[0].mData = mUserData[binCnt[kID]][kID].soundBuffer[0].data;
    bufList.mBuffers[0].mDataByteSize = samples * sizeof(AudioSampleType);

    // perform a synchronous sequential read of the audio data out of the file into our allocated data buffer
    UInt32 numPackets = numFrames;
    result = ExtAudioFileRead(xafref, &numPackets, &bufList);
    if (result) {
        printf("ExtAudioFileRead result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); 
        free(mUserData[binCnt[kID]][kID].soundBuffer[0].data);
        mUserData[binCnt[kID]][kID].soundBuffer[0].data = 0;
        return;
    }
    
    // update after the read to reflect the real number of frames read into the buffer
    // note that ExtAudioFile will automatically trim the 2112 priming frames off the AAC demo source
    mUserData[binCnt[kID]][kID].soundBuffer[0].numFrames = numPackets;
    
    // maxNumFrames is used to know when we need to loop the source
    mUserData[binCnt[kID]][kID].maxNumFrames = (mUserData[binCnt[kID]][kID].soundBuffer[0].numFrames > resolution * 44 * MAXTIMES ? resolution * 44 * MAXTIMES : mUserData[binCnt[kID]][kID].soundBuffer[0].numFrames);
    
    // close the file and dispose the ExtAudioFileRef
    ExtAudioFileDispose(xafref);
    binCnt[kID]++;
    if(binCnt[kID] >= MAXSNDS)  binCnt[kID] = 0;
}

- (void)loadMetro:(Float64)inGraphSampleRate
{
    
    metro.maxNumFrames = 0;
    
    printf("loadMetro\n");
    
    ExtAudioFileRef xafref = 0;
    
    NSString *source = [[NSBundle mainBundle] pathForResource:@"metro" ofType:@"aiff"];
    sourceURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, (CFStringRef)source, kCFURLPOSIXPathStyle, false);
    
    // open one of the two source files
    OSStatus result = ExtAudioFileOpenURL(sourceURL, &xafref);
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
    metro.soundBuffer[0].numFrames = numFrames;
    metro.soundBuffer[0].asbd = mClientFormat;
    
    UInt32 samples = numFrames * metro.soundBuffer[0].asbd.mChannelsPerFrame;
    metro.soundBuffer[0].data = (AudioSampleType *)calloc(samples, sizeof(AudioSampleType));
    
    // set up a AudioBufferList to read data into
    AudioBufferList bufList;
    bufList.mNumberBuffers = 1;
    bufList.mBuffers[0].mNumberChannels = metro.soundBuffer[0].asbd.mChannelsPerFrame;
    bufList.mBuffers[0].mData = metro.soundBuffer[0].data;
    bufList.mBuffers[0].mDataByteSize = samples * sizeof(AudioSampleType);
    
    // perform a synchronous sequential read of the audio data out of the file into our allocated data buffer
    UInt32 numPackets = numFrames;
    result = ExtAudioFileRead(xafref, &numPackets, &bufList);
    if (result) {
        printf("ExtAudioFileRead result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); 
        free(metro.soundBuffer[0].data);
        metro.soundBuffer[0].data = 0;
        return;
    }
    // update after the read to reflect the real number of frames read into the buffer
    // note that ExtAudioFile will automatically trim the 2112 priming frames off the AAC demo source
    metro.soundBuffer[0].numFrames = numPackets;
    
    // maxNumFrames is used to know when we need to loop the source
    metro.maxNumFrames = metro.soundBuffer[0].numFrames;
    
    // close the file and dispose the ExtAudioFileRef
    ExtAudioFileDispose(xafref);
    
}

- (void)loadWN:(Float64)inGraphSampleRate
{
    
    wn.maxNumFrames = 0;
    
    printf("loadWhiteNoise\n");
    
    ExtAudioFileRef xafref = 0;
    
    NSString *source = [[NSBundle mainBundle] pathForResource:@"WhiteNoise" ofType:@"aiff"];
    sourceURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, (CFStringRef)source, kCFURLPOSIXPathStyle, false);
    
    // open one of the two source files
    OSStatus result = ExtAudioFileOpenURL(sourceURL, &xafref);
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
    wn.soundBuffer[0].numFrames = numFrames;
    wn.soundBuffer[0].asbd = mClientFormat;
    
    UInt32 samples = numFrames * wn.soundBuffer[0].asbd.mChannelsPerFrame;
    wn.soundBuffer[0].data = (AudioSampleType *)calloc(samples, sizeof(AudioSampleType));
    
    // set up a AudioBufferList to read data into
    AudioBufferList bufList;
    bufList.mNumberBuffers = 1;
    bufList.mBuffers[0].mNumberChannels = wn.soundBuffer[0].asbd.mChannelsPerFrame;
    bufList.mBuffers[0].mData = wn.soundBuffer[0].data;
    bufList.mBuffers[0].mDataByteSize = samples * sizeof(AudioSampleType);
    
    // perform a synchronous sequential read of the audio data out of the file into our allocated data buffer
    UInt32 numPackets = numFrames;
    result = ExtAudioFileRead(xafref, &numPackets, &bufList);
    if (result) {
        printf("ExtAudioFileRead result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); 
        free(wn.soundBuffer[0].data);
        wn.soundBuffer[0].data = 0;
        return;
    }
    // update after the read to reflect the real number of frames read into the buffer
    // note that ExtAudioFile will automatically trim the 2112 priming frames off the AAC demo source
    wn.soundBuffer[0].numFrames = numPackets;
    
    // maxNumFrames is used to know when we need to loop the source
    wn.maxNumFrames = wn.soundBuffer[0].numFrames;
    
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
        cnt = 1;
        result = AUGraphStart(mGraph);
        if (result) { printf("AUGraphStart result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
    }
}

- (void)initShizuku
{
    // clear the mSoundBuffer struct
    for (int i=0; i<BIN; i++) {
        for (int j=0; j<MAXSNDS; j++) {
            memset(&mUserData[j][i].soundBuffer, 0, sizeof(mUserData[j][i].soundBuffer));
            binCnt[i] = 0;
        }
    }
    
    [self loadMetro:44100.0];
    [self loadWN:44100.0];
    
    for(int i=0; i<WN; i++) {
        shizuku[i].angle = 0;
        shizuku[i].area = 0;
        shizuku[i].color[0] = 0;
        shizuku[i].color[1] = 0;
        shizuku[i].color[2] = 0;
        shizuku[i].distance = -1;
        shizuku[i].frameNum = 0;
        shizuku[i].ID = 0;
        shizuku[i].note = 0;
        shizuku[i].sound = NULL;
        shizuku[i].isAlive = 0;
        shizuku[i].sn = -1;
        shizuku[i].posX = -1;
        shizuku[i].posY = -1;
    }
    
    time        = MAXTIMES-1;
    numShizuku  = 0;
    resolution  = 50;
    cnt         = 1;
    IDCnt       = 1;
    
    s_metro.angle       = 0;
    s_metro.area        = 0;
    s_metro.color[0]    = 0;
    s_metro.color[1]    = 0;
    s_metro.color[2]    = 0;
    s_metro.distance    = 0;
    s_metro.frameNum    = 0;
    s_metro.ID          = -1;
    s_metro.note        = 0;
    metroON             = true;
    
    s_wn.angle          = 0;
    s_wn.area           = 0;
    s_wn.color[0]       = 127;
    s_wn.color[1]       = 127;
    s_wn.color[2]       = 127;
    s_wn.distance       = 0;
    s_wn.frameNum       = 0;
    s_wn.ID             = -2;
    s_wn.note           = 0;
    
    printf("AUGraphController awakeFromNib\n");
    
    s_metro.sound = &metro;
    s_wn.sound = &wn;
    
    [self setRGB:WN];
    [self setReverb:50];
    [self setUplo];

    AudioUnitParameterValue value = 300.0;
    AudioUnitSetParameter(filterAU[WN], kMultibandFilter_LowFrequency, kAudioUnitScope_Global, 0, value, 0);
}

- (void)timer:(UInt64)sampleTime
{
    if (sampleTime > (float)resolution * 44.1 * (float)cnt) {
        cnt++;
        if(++time == MAXTIMES) {
            //send OSC Message
            lo_send(lo_address_new("localhost", "14999"),
                    "/daybreak",
                    "i",
                    0);
            
            time = 0;
        }
        
        if (metroON) [self metroCheck:time];
        
        for (UInt32 i=0; i<WN; i++) {
            //サウンド再生
            if (shizuku[i].distance == (SInt32)time) {
                
                //NULL音源チェック
                if (!shizuku[i].sound) { printf("err:play %d (null source)\n",shizuku[i].ID); [self deleteDrop:i]; continue; }
                
                //updateが来ていない水滴はdelete
                if (shizuku[i].isAlive <= 0) { NSLog(@"shizuku %d is not alive!",shizuku[i].ID); [self deleteDrop:i]; continue; }
                
                shizuku[i].note = 1;
                shizuku[i].frameNum = 0;
                printf("play %d\n",shizuku[i].ID);
                
                lo_send(lo_address_new("localhost", "13000"),
                        "/play",
                        "i",//Drop ID
                        shizuku[i].ID);
            }
        }
        
        //水滴の生存カウンタデクリメント
        if (cnt % 5 == 0) {//1秒毎(resolution: 50(ms) * 5 = 0.25(s))
            printf("cnt\n");
            for (int i=0; i<WN; i++) {
                if (shizuku[i].isAlive > 0) {
                    //カウンタが0になったら水滴の削除
                    if (--shizuku[i].isAlive <= 0) { printf("shibou\n"); [self deleteDrop:i]; }
                }
            }
        }
    }
}

- (void)metroCheck:(UInt32)t
{
    if (t % (MAXTIMES/4) == 0) {
        OSStatus result = AudioUnitSetParameter(vari_metroAU, kVarispeedParam_PlaybackCents, kAudioUnitScope_Global, 0, 1200, 0);
        if (result) { printf("AudioUnitSetParameter kTimePitchParam_Rate Global result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
        s_metro.frameNum = 0;
        s_metro.note = 1;
    }
    else if (t % (MAXTIMES/16) == 0) {

        OSStatus result = AudioUnitSetParameter(vari_metroAU, kVarispeedParam_PlaybackCents, kAudioUnitScope_Global, 0, 0, 0);
        if (result) { printf("AudioUnitSetParameter kTimePitchParam_Rate Global result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
        s_metro.frameNum = 0;
        s_metro.note = 1;

    }
}

- (void)playSound
{
    OSStatus result = AudioUnitSetParameter(vari_metroAU, kVarispeedParam_PlaybackCents, kAudioUnitScope_Global, 0, 0, 0);
    if (result) { printf("AudioUnitSetParameter kTimePitchParam_Rate Global result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
    s_metro.frameNum = 0;
    s_metro.note = 1;
}

Float32 calcDistance(int r1, int r2, int ang1, int ang2) {
    Float32 fR1 = (Float32)r1;
    Float32 fR2 = (Float32)r2;
    Float32 fAng = (Float32)ang1 - (Float32)ang2;

    Float32 retVal = pow(fR1, 2.0) + pow(fR2, 2.0) - 2*fR1*fR2*cos(2*M_PI*fAng/360.0);
    return sqrt(retVal);
}

Float32 calcDistanceXY(int x1, int x2, int y1, int y2) {
    Float32 fx1 = (Float32)x1;
    Float32 fx2 = (Float32)x2;
    Float32 fy1 = (Float32)y1;
    Float32 fy2 = (Float32)y2;
    
    Float32 retVal = pow(fx1-fx2, 2.0) + pow(fy1-fy2, 2.0);
    return sqrt(retVal);
}

bool isIdenticalRGB(Shizuku s, int R, int G, int B) {
    Float32 th = 30;
    Float32 dis = sqrt(pow((int)s.color[0]-R, 2.0)+pow((int)s.color[1]-G, 2.0)+pow((int)s.color[2]-B, 2.0));
    printf("RGB: %.2f\n", dis);
    if (dis < th) return true;
    else return false;
}

bool isIdenticalArea(Shizuku s, int area) {
    Float32 th = 30;
    Float32 dis = abs((int)s.area-area);
    
    printf("Area: %.2f\n", dis);
    if (dis < th) return true;
    else return false;
}

- (void)addDrop:(lo_arg **)dd;
{
    SInt32 j;
    int sound       = dd[0]->i-1;//BottleID:0~3

    for (j=WN-1; j>0; j--) {
        shizuku[j].angle      = shizuku[j-1].angle;
        shizuku[j].area       = shizuku[j-1].area;
        shizuku[j].color[0]   = shizuku[j-1].color[0];
        shizuku[j].color[1]   = shizuku[j-1].color[1];
        shizuku[j].color[2]   = shizuku[j-1].color[2];
        shizuku[j].distance   = shizuku[j-1].distance;
        shizuku[j].frameNum   = shizuku[j-1].frameNum;
        shizuku[j].isAlive    = shizuku[j-1].isAlive;
        shizuku[j].note       = shizuku[j-1].note;
        shizuku[j].sound      = shizuku[j-1].sound;
        shizuku[j].sn         = shizuku[j-1].sn;
        shizuku[j].ID         = shizuku[j-1].ID;
        shizuku[j].posX       = shizuku[j-1].posX;
        shizuku[j].posY       = shizuku[j-1].posY;
        
        [self setRGB:j];
        [self setAngle:j];
        [self setArea:j];
    }
    
    [self updateDrop:0 dropData:dd];
    
    shizuku[0].sn = (binCnt[sound] > 0 ? binCnt[sound]-1 : 0);
    shizuku[0].ID = IDCnt++;
    shizuku[0].frameNum   = 0;
    shizuku[0].note       = 0;
    
    //音源の割当て
    if (sound > -1) {
        if (shizuku[0].sn > -1) shizuku[0].sound = &mUserData[shizuku[0].sn][sound];
        else shizuku[0].sound = NULL;
    } else { shizuku[0].sound = NULL; return; }
    
    numShizuku++;
    NSLog(@"add! numShizuku:%d",numShizuku);

    return;
}

- (void)updateDrop:(SInt32 )n dropData:(lo_arg **)dd;
{ 
    int distance    = dd[1]->i;
    int area        = dd[2]->i;
    int angle       = dd[3]->i;
    int R           = dd[4]->i;
    int G           = dd[5]->i;
    int B           = dd[6]->i;
    int X           = dd[7]->i;
    int Y           = dd[8]->i;


    if (n == -1) return;
    
    shizuku[n].distance     = distance;
    shizuku[n].area         = area;
    shizuku[n].angle        = angle;
    shizuku[n].color[0]     = R;
    shizuku[n].color[1]     = G;
    shizuku[n].color[2]     = B;
    shizuku[n].isAlive      = 4;
    shizuku[n].posX         = X;
    shizuku[n].posY         = Y;
    
    [self setRGB:n];
    [self setAngle:n];
    [self setArea:n];
    
    return;
}

- (void)deleteDrop:(SInt32 )n
{
    UInt32 j;
    for (j=n; j<WN-1; j++) {
        shizuku[j].angle      = shizuku[j+1].angle;
        shizuku[j].area       = shizuku[j+1].area;
        shizuku[j].color[0]   = shizuku[j+1].color[0];
        shizuku[j].color[1]   = shizuku[j+1].color[1];
        shizuku[j].color[2]   = shizuku[j+1].color[2];
        shizuku[j].distance   = shizuku[j+1].distance;
        shizuku[j].frameNum   = shizuku[j+1].frameNum;
        shizuku[j].isAlive    = shizuku[j+1].isAlive;
        shizuku[j].note       = shizuku[j+1].note;
        shizuku[j].sound      = shizuku[j+1].sound;
        shizuku[j].sn         = shizuku[j+1].sn;
        shizuku[j].ID         = shizuku[j+1].ID;
        shizuku[j].posX       = shizuku[j+1].posX;
        shizuku[j].posY       = shizuku[j+1].posY;
        
        [self setRGB:j];
        [self setAngle:j];
        [self setArea:j];
    }
    
    shizuku[j].angle      = 0;
    shizuku[j].area       = 0;
    shizuku[j].color[0]   = 0;
    shizuku[j].color[1]   = 0;
    shizuku[j].color[2]   = 0;
    shizuku[j].distance   = -1;
    shizuku[j].frameNum   = 0;
    shizuku[j].note       = 0;
    shizuku[j].sound      = NULL;
    shizuku[j].sn         = -1;
    shizuku[j].ID         = 0;
    shizuku[j].isAlive    = 0;
    shizuku[j].posX       = -1;
    shizuku[j].posY       = -1;
    
    [self setRGB:j];
    [self setAngle:j];
    [self setArea:j];
    numShizuku--;
    NSLog(@"delete! numShizuku:%d",numShizuku);

    return;
}

- (int)serchIdenticalDrop:(lo_arg **)dd
{
    //int     distance    = dd[1]->i;
    //int     angle       = dd[3]->i;
    //int     area        = dd[2]->i;
    //int     R           = dd[4]->i;
    //int     G           = dd[5]->i;
    //int     B           = dd[6]->i;
    int     x1          = dd[7]->i;
    int     y1          = dd[8]->i;

    int     i           = 0;
    Float32 th          = 20;
    
    while (calcDistanceXY(shizuku[i].posX, x1, shizuku[i].posY, y1) > th) {
        if (++i == WN) return -1;
    }
    
    /*if(isIdenticalRGB(shizuku[i], R, G, B) && isIdenticalArea(shizuku[i], area)) return i;
    else return -1;*/
    
    return i;
}

int shizuku_add(const char *path, const char *types, lo_arg **argv, int argc,
                void *data, void *user_data)
{
    AUGraphController   *augc = (AUGraphController *)user_data;
    NSLog(@"%d,%d,%d,%d,%d,%d,%d,%d",
          argv[0]->i,
          argv[1]->i,
          argv[2]->i,
          argv[3]->i,
          argv[4]->i,
          argv[5]->i,
          argv[6]->i,
          argv[7]->i);

    if (argv[0]->i == 0) { NSLog(@"err:add (Bottle ID is not set!)"); return 0; }
    
    [augc addDrop:argv];
    
    return 0;
}

int shizuku_update(const char *path, const char *types, lo_arg **argv, int argc,
                   void *data, void *user_data)
{
    AUGraphController   *augc = (AUGraphController *)user_data;
    if (argv[0]->i == 0) { NSLog(@"err:update (Bottle ID is not set!)"); return 0; }

    int s = [augc serchIdenticalDrop:argv];
    
    if (s == -1) {//既存の水滴が見つからなかったときは水滴の追加
        printf("err:update\n");
        [augc addDrop:argv];
        
        return 0;
    }
    
    [augc updateDrop:s dropData:argv];
    printf("update!\n");
    
    //send OSC Message
    lo_send(lo_address_new("localhost", "13000"),
            "/update",
            "iiiii",//Drop ID, Bottle ID, Sound ID, posX, posY
            augc->shizuku[s].ID,
            argv[0]->i-1,
            augc->shizuku[s].sn,
            argv[7]->i,
            argv[8]->i);
    
    return 0;
}

int shizuku_delete(const char *path, const char *types, lo_arg **argv, int argc,
                   void *data, void *user_data)
{
    AUGraphController   *augc = (AUGraphController *)user_data;

    int s = [augc serchIdenticalDrop:argv];
    if (s == -1) { printf("err:delete\n"); return 0; }
    
    [augc deleteDrop:s];
    
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
    NSLog(@"routo");
    AUGraphController *augc = (AUGraphController *)user_data;

    int bn = argv[0]->i-1;
    [augc loadSpeechTrack:44100.0 kobin:bn];
    return 0;
}

int head_handler(const char *path, const char *types, lo_arg **argv, int argc,
                  void *data, void *user_data)
{
    NSLog(@"head");

    lo_send(lo_address_new("localhost", "13000"),
            "/head",
            "i",
            argv[0]->i);
    
    return 0;
}

int start_handler(const char *path, const char *types, lo_arg **argv, int argc,
                 void *data, void *user_data)
{
    NSLog(@"start");
    AUGraphController *augc = (AUGraphController *)user_data;
    [augc addMethod];
    return 0;
}

int sound_handler(const char *path, const char *types, lo_arg **argv, int argc,
                  void *data, void *user_data)
{
    NSLog(@"sound");
    AUGraphController *augc = (AUGraphController *)user_data;
    [augc playSound];
    return 0;
}

- (void)setUplo
{
    st = lo_server_thread_new("15000", NULL);
    lo_server_thread_add_method(st, "/start", "i", start_handler, self);
    lo_server_thread_start(st);
}

- (void)addMethod
{
    //lo_server_thread_add_method(st, "/add", "iiiiiiiii", shizuku_add, self);
    lo_server_thread_add_method(st, "/existed", "iiiiiiiii", shizuku_update, self);
    //lo_server_thread_add_method(st, "/delete", "iiiiiiiii", shizuku_delete, self);
    lo_server_thread_add_method(st, "/head", "i", head_handler, self);
    lo_server_thread_add_method(st, "/user", "iii", user_handler, self);
    lo_server_thread_add_method(st, "/routo", "i", routo_handler, self);
    lo_server_thread_add_method(st, "/sound", "i", sound_handler, self);

}

- (void)toggleMetro
{
    if (metroON) metroON = false;
    else metroON = true;
}

- (void)toggleWN
{
    if (s_wn.note) s_wn.note = false;
    else s_wn.note = true;
}

- (void)setRGB:(UInt32)n
{
    AudioUnitParameterValue lg;
    AudioUnitParameterValue c2;
    AudioUnitParameterValue hg;
    
    if (n < WN) {
        lg = ((float)shizuku[n].color[0]-255.0)*18.0/255.0;
        c2 = ((float)shizuku[n].color[1]-255.0)*18.0/255.0;
        hg = ((float)shizuku[n].color[2]-255.0)*18.0/255.0;
    }else {
        lg = ((float)s_wn.color[0]-255.0)*40.0/255.0;
        c2 = ((float)s_wn.color[1]-255.0)*40.0/255.0;
        hg = ((float)s_wn.color[2]-255.0)*40.0/255.0;
    }
    
    AudioUnitParameterValue c1 = (lg+c2)/2.0;
    AudioUnitParameterValue c3 = (hg+c2)/2.0;

    OSStatus result = AudioUnitSetParameter(filterAU[n], kMultibandFilter_LowGain, kAudioUnitScope_Global, 0, lg, 0);
    if (result) { printf("kMultibandFilter_LowGain result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
    
    result = AudioUnitSetParameter(filterAU[n], kMultibandFilter_CenterGain1, kAudioUnitScope_Global, 0, c1, 0);
    if (result) { printf("kMultibandFilter_CenterGain1 result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
    
    result = AudioUnitSetParameter(filterAU[n], kMultibandFilter_CenterGain2, kAudioUnitScope_Global, 0, c2, 0);
    if (result) { printf("kMultibandFilter_CenterGain2 result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
    
    result = AudioUnitSetParameter(filterAU[n], kMultibandFilter_CenterGain3, kAudioUnitScope_Global, 0, c3, 0);
    if (result) { printf("kMultibandFilter_CenterGain3 result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
    
    result = AudioUnitSetParameter(filterAU[n], kMultibandFilter_HighGain, kAudioUnitScope_Global, 0, hg, 0);
    if (result) { printf("kMultibandFilter_HighGain result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
    
    //printf("filter gain:%.1f %.1f %.1f %.1f %.1f\n",lg, c1, c2, c3, hg);
}

- (void)setR:(AudioUnitParameterValue)n
{
    s_wn.color[0] = n;
}
- (void)setG:(AudioUnitParameterValue)n
{
    s_wn.color[1] = n;
}
- (void)setB:(AudioUnitParameterValue)n
{
    s_wn.color[2] = n;
}

- (void)setAngle:(UInt32)n
{
    SInt32 value;
    if (shizuku[n].angle > 180) {
        value = (shizuku[n].angle-180)%15;
    } else {
        value = (180-shizuku[n].angle)%15;
    }
    AudioUnitParameterValue cent = 0.0;
    
    //cent = ((float)shizuku[n].angle-180.0)*20.0/3.0;
    
    switch (value) {
        case 0:
            cent = 1200.0;
            break;
        
        case 1:
            cent = 900.0;
            break;
        
        case 2:
            cent = 700.0;
            break;
        
        case 3:
            cent = 400.0;
            break;
            
        case 4:
            cent = 200.0;
            break;
            
        case 5:
            cent = 0.0;
            break;
            
        case 6:
            cent = 0.0;
            break;
            
        case 7:
            cent = -300.0;
            break;
            
        case 8:
            cent = -500.0;
            break;
            
        case 9:
            cent = -800.0;
            break;
            
        case 10:
            cent = -1000.0;
            break;
            
        case 11:
            cent = -1200.0;
            break;
            
        default:
            break;
    }
    OSStatus result = AudioUnitSetParameter(mTimeAU[n], kVarispeedParam_PlaybackCents, kAudioUnitScope_Global, 0, cent, 0);
    if (result) { printf("AudioUnitSetProperty result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
}

- (void)setArea:(UInt32)n
{
    AudioUnitParameterValue volume;
    volume = (float)shizuku[n].area/1000.0;
    
    OSStatus result = AudioUnitSetParameter(mMixer, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, n, volume, 0);
    if (result) { printf("AudioUnitSetProperty result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
}

- (void)setReverb:(AudioUnitParameterValue)n//0<n<100 
{    

    OSStatus result = AudioUnitSetParameter(reverbAU, kReverbParam_DryWetMix, kAudioUnitScope_Global, 0, n, 0);
    if (result) { printf("AudioUnitSetProperty result %ld %08X %4.4s\n", (long)result, (unsigned int)result, (char*)&result); return; }
    
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