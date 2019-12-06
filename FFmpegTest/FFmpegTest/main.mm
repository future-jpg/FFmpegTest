//
//  main.m
//  FFmpegTest
//
//  Created by xulei on 2019/12/6.
//  Copyright © 2019 xulei. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "AppDelegate.h"

//int main(int argc, char * argv[]) {
//    NSString * appDelegateClassName;
//    @autoreleasepool {
//        // Setup code that might create autoreleased objects goes here.
//        appDelegateClassName = NSStringFromClass([AppDelegate class]);
//    }
//    return UIApplicationMain(argc, argv, nil, appDelegateClassName);
//}

extern "C"{  //C++中需要申明extern "C"来确定引入c文件
#include "SDL.h"
#include "SDL_thread.h"
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavformat/avio.h>
#include <libswscale/swscale.h>
#include <libavutil/avstring.h>
#include <libavutil/imgutils.h>
#include <libswresample/swresample.h>
#include <libavutil/opt.h>
}
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>


typedef struct PacketQueue{
    AVPacketList *first_pkt, *last_pkt;
    int nb_packets;
    int size;
    SDL_mutex *mutex;
    SDL_cond *cond;
}PacketQueue;

int main(int argc, char *argv[]) {
    SDL_Event event;
    AVFormatContext* formatContext = avformat_alloc_context();//初始化AVFormatContext
    AVCodecContext* codeContext = NULL;
    AVCodecContext* audioCodeContext = NULL;
    
    SDL_AudioSpec wanted_spec, spec;
    
    int videoIndex = -1;
    int audioIndex = -1;
    av_register_all();//一劳永逸，第一步注册所有的文件格式以及编码器 deprecated
    SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO | SDL_INIT_TIMER);//初始化SDL
    SDL_Window* window = SDL_CreateWindow("", 0, 0, [UIScreen mainScreen].bounds.size.width, [UIScreen mainScreen].bounds.size.height, SDL_WINDOW_OPENGL|SDL_WINDOW_MAXIMIZED);//创建SDL_Window,类似于iOS中的UIWindow
    SDL_Renderer* renderer = SDL_CreateRenderer(window, -1, 0);//创建SDL_Renderer
    
    NSString * path = [[NSBundle  mainBundle]pathForResource:@"video.mp4" ofType:@""];//获取文件路径
    
    if(0!=avformat_open_input(&formatContext, [path UTF8String], NULL, NULL)){
        return -1;//第二步打开文件，并存入formatContext中。
    }
    
    if(0!=avformat_find_stream_info(formatContext, NULL)){
        return -1;//第三步从formatContext对象中读取AVStream信息.
    }
    
    for(int i = 0;i<formatContext->nb_streams;i++){
        AVStream * stream = formatContext->streams[i];
        if(stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO){//第四步遍历formatContext中的所有数据流。从中选出视频流
            AVCodec* codec = avcodec_find_decoder(stream->codecpar->codec_id);//第五步，根据流的信息找到对应的解码器。
            codeContext = avcodec_alloc_context3(codec);
            avcodec_parameters_to_context(codeContext, stream->codecpar);//根据视频流信息获得对应的编解码器对象相关信息。
            videoIndex = i;
            break;
        }
        if(stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO){
            AVCodec* codec = avcodec_find_decoder(stream->codecpar->codec_id);
            audioCodeContext = avcodec_alloc_context3(codec);
            audioIndex = i;
            break;
        }
    }
    
    wanted_spec.freq = audioCodeContext->sample_rate;
    wanted_spec.format = AUDIO_S16SYS;
    wanted_spec.channels = audioCodeContext->channels;
    wanted_spec.silence = 0;
    wanted_spec.samples = SDL_GL_BUFFER_SIZE;;
    wanted_spec.callback = audio_callback;
    wanted_spec.userdata = audioCodeContext;
    if (SDL_OpenAudio(&wanted_spec, &spec) < 0){
        return -1;
    }
    
    avcodec_open2(audioCodeContext, audioCodeContext->codec, <#AVDictionary **options#>)
    
    if(codeContext == NULL)
        return -1;
    
    const AVCodec* codec = codeContext->codec;
    if(0!=avcodec_open2(codeContext, codec, NULL))//第六步，打开编解码器
        return -1;
    
    AVPacket* packet = av_packet_alloc();//用于暂存压缩帧的临时对象。
    AVFrame* frame = av_frame_alloc();   //用于暂存解压缩帧的临时对象。
    
    AVFrame* pFrameYUV = av_frame_alloc();   //由于解压缩帧不能直接用于SDL展示，因此需要对解压缩帧进行格式转换，pFrameYUV就是用来暂存格式转换后的临时对象。
    
    //由于AVFrame是一个对象，并非只包含解压缩帧的数据，还会包含一些其他数据,并且av_frame_alloc只是为pFrameYUV对象分配了内存，并没有为pFrameYUV对象中真正存储数据的对象分配内存，因此下面要对这个真正存储数据的对象分配内存。
    int numBytes = avpicture_get_size(AV_PIX_FMT_YUV420P, codeContext->width, codeContext->height);//得到这个帧的大小
    uint8_t* buffer = (uint8_t*)av_malloc(numBytes*sizeof(uint8_t));//按照uint8_t分配内存，
    avpicture_fill((AVPicture*)pFrameYUV, buffer, AV_PIX_FMT_YUV420P, codeContext->width, codeContext->height);//将pFrameYUV中存储数据的对象与刚才分配的内存关联起来。
    
    SwsContext* sws_context = sws_getContext(codeContext->width, codeContext->height,
                                             codeContext->pix_fmt, codeContext->width,
                                             codeContext->height, AV_PIX_FMT_YUV420P,
                                             SWS_BILINEAR, NULL, NULL, NULL
                                             );//创建frame以及pFrameYUV帧转换的容器
    
    SDL_Texture* bmp = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_IYUV, SDL_TEXTUREACCESS_STREAMING, codeContext->width, codeContext->height);//创建SDL_Texture对象，使用SDL_PIXELFORMAT_IYUV格式
    SDL_Rect rect;
    rect.x = 0;
    rect.y = 0;
    rect.w = codeContext->width;
    rect.h = codeContext->height;
    
    
    while(0==av_read_frame(formatContext, packet)){//第八步从文件中读取压缩帧。
        if(packet->stream_index == videoIndex){//如果这个压缩帧是视频压缩帧
            int getFrame = 0;
            int ret =  avcodec_decode_video2(codeContext, frame, &getFrame, packet);//解压这个压缩帧
            if(getFrame){
                sws_scale(sws_context, (uint8_t const * const *)frame->data, frame->linesize, 0,
                          codeContext->height, pFrameYUV->data, pFrameYUV->linesize);// 使用刚才创建的转换器，将解压缩帧转变成可以使用SDL展示的解压缩帧。
                SDL_UpdateTexture(bmp, &rect, pFrameYUV->data[0], pFrameYUV->linesize[0]);//将解压缩帧渲染到Texture上。
                SDL_RenderClear(renderer); //清除当前Render上的图片
                SDL_RenderCopy(renderer, bmp, NULL, NULL);//将Texture渲染到Render上
                SDL_RenderPresent(renderer);// 展示图片到界面上
                SDL_Delay(10);//延迟10ms
                
                
                //以下代码我还没完全理解，为什么一定要添加才能让SDL连续展示图片.
                SDL_PollEvent(&event);
                switch (event.type) {
                    case SDL_QUIT:
                        SDL_Quit();
                        exit(0);
                        break;
                    default:
                        break;
                }
                
            }
            
        }
        
    }
    
    
    av_frame_free(&frame);
    av_frame_free(&pFrameYUV);
    
    av_packet_free(&packet);
    avcodec_close(codeContext);
    avformat_close_input(&formatContext);
    
    return 0;
}

void packet_queue_init(PacketQueue *q){
    memset(q, 0, sizeof(PacketQueue));
    q->mutex = SDL_CreateMutex();
    q->cond = SDL_CreateCond();
}

int packet_queue_put(PacketQueue *q,AVPacket *pkt) {
    AVPacketList *pktl;
    if (av_packet_ref(pkt, pkt) < 0){
        return -1;
        
    }
    
    pktl = (AVPacketList *) av_malloc(sizeof(AVPacketList));
    if(!pktl){
        return -1;
    }
    
    pktl->pkt = *pkt;
    pktl->next = NULL;
    
    SDL_LockMutex(q->mutex);
    if(!q->last_pkt){
        q->first_pkt = pktl;
    }else{
        q->last_pkt->next = pktl;
    }
    
    q->last_pkt = pktl;
    q->nb_packets ++;
    q->size += pktl->pkt.size;
    SDL_CondSignal(q->cond);
    SDL_UnlockMutex(q->mutex);
    return 0;
}

