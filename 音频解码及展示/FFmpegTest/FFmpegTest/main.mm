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

#define SDL_AUDIO_BUFFER_SIZE 1024
#define MAX_AUDIO_FRAME_SIZE 192000

int quit = 0;
PacketQueue audioq;
AVFrame wanted_frame;

void packet_queue_init(PacketQueue *q) {
    memset(q, 0, sizeof(PacketQueue));
    q->mutex = SDL_CreateMutex();
    q->cond = SDL_CreateCond();
}

int packet_queue_put(PacketQueue *q, AVPacket *pkt) {
    AVPacketList *pktl;
    if (av_packet_ref(pkt, pkt) < 0){
        return -1;
    }

    pktl = (AVPacketList *)av_malloc(sizeof(AVPacketList));
    if (!pktl) {
        return -1;
    }

    pktl->pkt = *pkt;

    SDL_LockMutex(q->mutex);

    if (!q->last_pkt) {
        q->first_pkt = pktl;
    } else {
        q->last_pkt->next = pktl;
    }

    q->last_pkt = pktl;
    q->nb_packets ++ ;
    q->size += pktl->pkt.size;
    SDL_CondSignal(q->cond);

    SDL_UnlockMutex(q->mutex);
    return 0;
}

static int packet_queue_get(PacketQueue *q, AVPacket *pkt, int block) {
    AVPacketList *pktl;
    int ret;

    SDL_LockMutex(q->mutex);

    do{
        if (quit) {
            ret = -1;
            break;
        }
        pktl = q->first_pkt;
        if (pktl) {
            q->first_pkt = pktl->next;
            if (!q->first_pkt) {
                q->last_pkt = NULL;
            }

            q->nb_packets--;
            q->size -= pktl->pkt.size;
            *pkt = pktl->pkt;
            av_free(pktl);
            ret = 1;
            break;
        } else if (!block) {
            ret = 0;
            break;
        } else {
            SDL_CondWait(q->cond, q->mutex);//Wait on the condition variable, unlocking the provided mutex.
        }
    }while(true);
    SDL_UnlockMutex(q->mutex);
    return ret;
}

int audio_decode_frame(AVCodecContext *aCodecCtx, uint8_t * audio_buf, int buf_size) {
    static AVPacket thisPkt;
    static AVFrame frame;
    SwrContext *resample_ctx = NULL;
    int resampled_data_size;
    int data_size = 0;
    
    int output_channels = 2;
    int output_rate = 48000;
    int input_channels = aCodecCtx->channels;
    int input_rate = aCodecCtx->sample_rate;
    AVSampleFormat input_sample_fmt = aCodecCtx->sample_fmt;
    AVSampleFormat output_sample_fmt = AV_SAMPLE_FMT_S16;
    printf("channels[%d=>%d],rate[%d=>%d],sample_fmt[%d=>%d]\n",
        input_channels,output_channels,input_rate,output_rate,input_sample_fmt,output_sample_fmt);

    resample_ctx = swr_alloc_set_opts(resample_ctx, av_get_default_channel_layout(output_channels),output_sample_fmt,output_rate,
                                av_get_default_channel_layout(input_channels),input_sample_fmt, input_rate,0,NULL);
    swr_init(resample_ctx);
    
    do{
        while (0 == avcodec_receive_frame(aCodecCtx, &frame)) {
            
//            data_size = av_samples_get_buffer_size(NULL, aCodecCtx->channels, frame.nb_samples, aCodecCtx->sample_fmt, 1);
//            memcpy(audio_buf, frame.data[0], data_size);
            
//
//            if (data_size <= 0){
//                continue;
//            }
//
//            printf("saving frame %3d\n", aCodecCtx->frame_number);
//            data_size = frame.nb_samples * av_get_bytes_per_sample((AVSampleFormat)frame.format);
                                
            //resample
            memset(audio_buf,0x00,MAX_AUDIO_FRAME_SIZE);
            int out_samples = swr_convert(resample_ctx,&audio_buf,frame.nb_samples,(const uint8_t **)frame.data,frame.nb_samples);
            if(out_samples > 0){
                resampled_data_size =  av_samples_get_buffer_size(NULL,output_channels ,out_samples, output_sample_fmt, 1);//out_samples*output_channels*av_get_bytes_per_sample(output_sample_fmt);
            } else {
                return -1;
            }
            swr_free(&resample_ctx);
            return resampled_data_size;
        }

        if (thisPkt.data) {
            av_packet_unref(&thisPkt);
        }

        if (quit) {
            return -1;
        }

        if (packet_queue_get(&audioq, &thisPkt, 1) < 0) {
            return -1;
        } else {
            avcodec_send_packet(aCodecCtx, &thisPkt);
        }



    }while(true);
}

void audio_callback(void *userdata, uint8_t *stream, int len) {
    AVCodecContext *aCodecCtx = (AVCodecContext *)userdata;
    int lenl ,audio_size;
    static uint8_t audio_buf[(MAX_AUDIO_FRAME_SIZE * 3)/2];
    static unsigned int audio_buf_size = 0;
    static unsigned int audio_buf_index = 0;

    while (len > 0) {
        if (audio_buf_index >= audio_buf_size) {
            audio_size = audio_decode_frame(aCodecCtx, audio_buf, audio_buf_size);
            if (audio_size < 0 ) {
                audio_buf_size = 1024;
                memset(audio_buf, 0, audio_buf_size);
            } else {
                audio_buf_size = audio_size;
            }
            audio_buf_index = 0;
        }

        lenl = audio_buf_size - audio_buf_index;
        if (lenl > len) {
            lenl = len;
        }

        memcpy(stream, (uint8_t *)audio_buf + audio_buf_index, lenl);
        len -= lenl;
        stream += lenl;
        audio_buf_index += lenl;
    }


}

int main(int argc, char *argv[]) {
    SDL_Event event;
    AVFormatContext* formatContext = avformat_alloc_context();//初始化AVFormatContext
    AVCodecContext* codeContext = NULL;
    int audioIndex = -1;
    av_register_all();//一劳永逸，第一步注册所有的文件格式以及编码器 deprecated
    SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO | SDL_INIT_TIMER);//初始化SDL

    NSString * path = [[NSBundle  mainBundle]pathForResource:@"video.mp4" ofType:@""];//获取文件路径

    if(0!=avformat_open_input(&formatContext, [path UTF8String], NULL, NULL)){
        return -1;//第二步打开文件，并存入formatContext中。
    }

    if(0!=avformat_find_stream_info(formatContext, NULL)){
        return -1;//第三步从formatContext对象中读取AVStream信息.
    }
    AVCodec* codec = NULL;
    AVPacket packet;

    for(int i = 0;i<formatContext->nb_streams;i++){
        AVStream * stream = formatContext->streams[i];
        if(stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO){//第四步遍历formatContext中的所有数据流。从中选出视频流
            codec = avcodec_find_decoder(stream->codecpar->codec_id);//第五步，根据流的信息找到对应的解码器。
            codeContext = stream->codec;
            audioIndex = i;
            break;
        }
    }
    if(codeContext == NULL)
        return -1;

    SDL_AudioSpec   wanted_spec, spec;

    wanted_spec.freq = codeContext->sample_rate;
    wanted_spec.format = AUDIO_S16SYS;
    wanted_spec.channels = codeContext->channels;
    wanted_spec.silence = 0;
    wanted_spec.samples = SDL_AUDIO_BUFFER_SIZE;
    wanted_spec.callback = audio_callback;
    wanted_spec.userdata = codeContext;

    if(SDL_OpenAudio(&wanted_spec, &spec) < 0)
    {
        fprintf(stderr, "SDL_OpenAudio: %s \n", SDL_GetError());
        return -1;
    }

    wanted_frame.format = AV_SAMPLE_FMT_S16;
    wanted_frame.sample_rate = spec.freq;
    wanted_frame.channel_layout = av_get_default_channel_layout(spec.channels);
    wanted_frame.channels = spec.channels;

    avcodec_open2(codeContext, codec, NULL);

    packet_queue_init(&audioq);
    SDL_PauseAudio(0);

    if(0!=avcodec_open2(codeContext, codec, NULL))//第六步，打开编解码器
        return -1;

    while (av_read_frame(formatContext, &packet) >= 0)
    {
        if (packet.stream_index == audioIndex)
            packet_queue_put(&audioq, &packet);
        else
            av_free_packet(&packet);

        SDL_PollEvent(&event);
        switch (event.type) {
            case SDL_QUIT:
                quit = 1;
                SDL_Quit();
                exit(0);
                break;

            default:
                break;
        }
    }
//
//  在控制台输出文件信息
    av_dump_format(formatContext, 0, [[[NSBundle mainBundle] pathForResource:@"test.mp3" ofType:@""] UTF8String], 0);

    return 0;
}
