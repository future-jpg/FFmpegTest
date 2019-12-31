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

#define SDL_AUDIO_BUFFER_SIZE 1024
#define MAX_AUDIO_FRAME_SIZE 192000

#define MAX_AUDIOQ_SIZE (5 * 16 * 1024)
#define MAX_VIDEOQ_SIZE (5 * 256 * 1024)

#define FF_ALLOC_EVENT (SDL_USEREVENT)
#define FF_REFRESH_EVENT (SDL_USEREVENT + 1)
#define FF_QUIT_EVENT (SDL_USEREVENT + 2)

#define VIDEO_PICTURE_QUEUE_SIZE 1

#define AV_SYNC_THRESHOLD 0.01
#define AV_NOSYNC_THRESHOLD 10.0

SDL_Window* window;
SDL_Renderer* renderer;
SDL_Texture *bmp;
uint8_t *buffer;
BOOL flag = false;

// 顺时针旋转 ffmpeg avframe yuv  rotation
void Rotate90(const AVFrame* src, AVFrame* dst)
{
    int half_width = src->width >> 1;
    int half_height = src->height >> 1;
 
    int size = src->linesize[0] * src->height;
    int half_size = size >> 2;

    for (int j = 0, n = 0; j < src->width; j++) {
        int pos = size;
        for (int i = src->height - 1; i >= 0; i--) {
            pos -= src->linesize[0];
            dst->data[0][n++] = src->data[0][pos + j];
        
        }
        
    }
 
    for (int j = 0, n = 0; j < half_width; j++) {
        int pos = half_size;
        for (int i = half_height - 1; i >= 0; i--) {
            pos -= src->linesize[1];
            dst->data[1][n] = src->data[1][pos + j];
            dst->data[2][n++] = src->data[2][pos + j];
            
        }
    }
    dst->height = src->width;
    dst->width = src->height;
}

typedef struct PacketQueue {
    AVPacketList *first_pkt, *last_pkt;
    int nb_packets;
    int size;
    NSCondition *cond;
} PacketQueue;


typedef struct VideoPicture {
    AVFrame *pFrameYUV;
    int width, height; // Source height & width.
    int allocated;
    double  pts;
} VideoPicture;

typedef struct VideoState {
    AVFormatContext *pFormatCtx;
    int videoStream, audioStream;
    
    double audio_clock;
    AVStream *audio_st;
    PacketQueue audioq;
    AVFrame audio_frame;
    uint8_t audio_buf[(MAX_AUDIO_FRAME_SIZE * 3) / 2];
    unsigned int audio_buf_size;
    unsigned int audio_buf_index;
    AVPacket audio_pkt;
    uint8_t *audio_pkt_data;
    int audio_pkt_size;
    int audio_hw_buf_size;
    double frame_timer;
    double frame_last_pts;
    double frame_last_delay;
    double video_clock; 
    AVStream *video_st;
    PacketQueue videoq;
    
    VideoPicture pictq[VIDEO_PICTURE_QUEUE_SIZE];
    int pictq_size, pictq_rindex, pictq_windex;
    
    NSCondition *pictq_cond;
    
    char filename[1024];
    int quit;
    
    AVIOContext *io_context;
    struct SwsContext *sws_ctx;
} VideoState;
SDL_mutex *screen_mutex;

// Since we only have one decoding thread, the Big Struct can be global in case we need it.
VideoState *global_video_state;
PacketQueue audioq;

void packet_queue_init(PacketQueue *q) {
    memset(q, 0, sizeof(PacketQueue));
    q->first_pkt = NULL;
    q->last_pkt = NULL;
    q->cond = [[NSCondition alloc] init];
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
    pktl->next = NULL;

    [q->cond lock];

    if (!q->last_pkt) {
        q->first_pkt = pktl;
    } else {
        q->last_pkt->next = pktl;
    }

    q->last_pkt = pktl;
    q->nb_packets ++ ;
    q->size += pktl->pkt.size;
    [q->cond signal];

    [q->cond unlock];
    return 0;
}

static int packet_queue_get(PacketQueue *q, AVPacket *pkt, int block) {
    AVPacketList *pktl = NULL;
    int ret;

    [q->cond lock];
   

    do{
        if (global_video_state->quit) {
            ret = -1;
            break;
        }
        pktl = q->first_pkt;
        if (pktl && q->nb_packets > 0) {
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
            [q->cond wait];
        }
    }while(true);
    [q->cond unlock];
    return ret;
}

double get_audio_clock(VideoState *is) {
    double pts;
    int hw_buf_size, bytes_per_sec, n;
    
    pts = is->audio_clock;
    hw_buf_size = is->audio_buf_size - is->audio_buf_index;
    bytes_per_sec = 0;
 
    n = is->audio_st->codec->channels * 2;//2是指量化精度，一般是16bit = 2 B；
 
    if (is->audio_st) {
        bytes_per_sec = is->audio_st->codec->sample_rate * n;
    }
    if (bytes_per_sec) {
        pts -= (double) hw_buf_size / bytes_per_sec;
    }
    return pts;
}

int audio_decode_frame(VideoState *is) {
    static AVPacket* thisPkt = &is->audio_pkt;
    static AVFrame frame;
    SwrContext *resample_ctx = NULL;
    int resampled_data_size;
    int data_size = 0;
    AVCodecContext *aCodecCtx = is->audio_st->codec;
    int output_channels = 2;
    int output_rate = 44100;
    int input_channels = aCodecCtx->channels;
    int input_rate = aCodecCtx->sample_rate;
    AVSampleFormat input_sample_fmt = aCodecCtx->sample_fmt;
    AVSampleFormat output_sample_fmt = AV_SAMPLE_FMT_S16;

    resample_ctx = swr_alloc_set_opts(resample_ctx, av_get_default_channel_layout(output_channels),output_sample_fmt,output_rate,
                                av_get_default_channel_layout(input_channels),input_sample_fmt, input_rate,0,NULL);
    swr_init(resample_ctx);

    do{
        while (0 == avcodec_receive_frame(aCodecCtx, &frame)) {
            uint8_t *audio_buf = is->audio_buf;
            int out_samples = swr_convert(resample_ctx, &audio_buf, frame.nb_samples, (const uint8_t **)frame.data, frame.nb_samples);
            if(out_samples > 0){
                resampled_data_size =  av_samples_get_buffer_size(NULL,output_channels ,out_samples, output_sample_fmt, 1);//out_samples*output_channels*av_get_bytes_per_sample(output_sample_fmt);
            } else {
                return -1;
            }
            swr_free(&resample_ctx);
            
            int n = 2 * output_channels;
            is->audio_clock += (double) resampled_data_size / (double) (n * output_rate);
            
            
            return resampled_data_size;
        }

        if (thisPkt->data) {
            av_packet_unref(thisPkt);
        }

        if (global_video_state->quit) {
            return -1;
        }

        if (packet_queue_get(&is->audioq, thisPkt, 1) < 0) {
            return -1;
        } else {
            avcodec_send_packet(aCodecCtx, thisPkt);
        }

        is->audio_pkt_data = thisPkt->data;
        is->audio_pkt_size = thisPkt->size;
        if (thisPkt->pts != AV_NOPTS_VALUE) {
            is->audio_clock = av_q2d(is->audio_st->time_base) * thisPkt->pts;
        }

    }while(true);
}

void audio_callback(void *userdata, uint8_t *stream, int len) {
    VideoState *is = (VideoState *)userdata;
    int lenl ,audio_size;

    while (len > 0) {
        if (is->audio_buf_index >= is->audio_buf_size) {
            audio_size = audio_decode_frame(is);
            if (audio_size < 0 ) {
                is->audio_buf_size = 1024;
                memset(is->audio_buf, 0, is->audio_buf_size);
            } else {
                is->audio_buf_size = audio_size;
            }
            is->audio_buf_index = 0;
        }

        lenl = is->audio_buf_size - is->audio_buf_index;
        if (lenl > len) {
            lenl = len;
        }

        memcpy(stream, (uint8_t *)is->audio_buf + is->audio_buf_index, lenl);
        len -= lenl;
        stream += lenl;
        is->audio_buf_index += lenl;
    }
}

double synchronize_video(VideoState* is, AVFrame *src_frame, double pts) {
    double frame_delay;
    if (pts!=0){
        is->video_clock = pts;
    } else {
        pts = is->video_clock;
    }
    
    frame_delay = av_q2d(is->video_st->codec->time_base);
    frame_delay += src_frame->repeat_pict * (frame_delay * 0.5);
    is->video_clock += frame_delay;
    return pts;
}

void video_display(VideoState *is) {
    SDL_Rect rect;
    VideoPicture *vp;
    [is->pictq_cond lock];
    vp = &is->pictq[is->pictq_rindex];
    [is->pictq_cond unlock];
    if (vp->pFrameYUV) {
        rect.x = 0;
        rect.y = 0;
        rect.w = is->video_st->codec->width ;
        rect.h = is->video_st->codec->height;
         
        SDL_UpdateTexture(bmp, &rect, vp->pFrameYUV->data[0], vp->pFrameYUV->linesize[0]);//将解压缩帧渲染到Texture上。
        SDL_RenderClear(renderer); //清除当前Render上的图片
        SDL_RenderCopy(renderer, bmp, NULL, NULL);//将Texture渲染到Render上
        SDL_RenderPresent(renderer);// 展示图片到界面上
    }
}

void video_refresh_timer(void *userdata) {

    VideoState *is = (VideoState *)userdata;
    VideoPicture *vp;
    
    double actual_delay,delay,sync_threshold,ref_clock,diff;

    if (is->video_st) {
        if (is->pictq_size == 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.001 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                video_refresh_timer(is);
            });
        } else {
            vp = &is->pictq[is->pictq_rindex];
            
            delay = vp->pts - is->frame_last_pts;
            if (delay <= 0 || delay >= 1.0) {
                delay = is->frame_last_delay;
            }
        
            is->frame_last_delay = delay;
            is->frame_last_pts = vp->pts;
            
            ref_clock = get_audio_clock(is);
            diff = vp->pts - ref_clock;
            
            sync_threshold = (delay > AV_SYNC_THRESHOLD) ? delay : AV_SYNC_THRESHOLD;
            if (fabs(diff) < AV_NOSYNC_THRESHOLD) {
                if (diff <= -sync_threshold) {
                    delay = 0;
                } else if (diff >= sync_threshold) {
                    delay = 2 * delay;
                }
            }
            is->frame_timer += delay;
            actual_delay = is->frame_timer - (av_gettime() / 1000000.0);
            if (actual_delay < 0.010) {
                actual_delay = 0.010;
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(actual_delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                video_refresh_timer(is);
            });
 
            video_display(is);
 
            if (++is->pictq_rindex == VIDEO_PICTURE_QUEUE_SIZE) {
                is->pictq_rindex = 0;
            }
            [is->pictq_cond lock];
            is->pictq_size--;
            [is->pictq_cond signal];
            [is->pictq_cond unlock];
        }
    } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            video_refresh_timer(is);
        });
    }
}

void alloc_picture(void *userdata) {
    
    VideoState *is = (VideoState *)userdata;
    VideoPicture *vp;
    
    [is->pictq_cond lock];
    vp = &is->pictq[is->pictq_windex];
 
    [is->pictq_cond unlock];
    if (vp->pFrameYUV) {
        av_frame_free(&vp->pFrameYUV);
    }
    vp->pFrameYUV = av_frame_alloc();
    vp->width = is->video_st->codec->height;
    vp->height = is->video_st->codec->width;
    
    [is->pictq_cond lock];
    vp->allocated = 1;
    [is->pictq_cond signal];
    [is->pictq_cond unlock];
}

int queue_picture(VideoState *is, AVFrame *pFrame, double pts) {
    VideoPicture *vp;
 
    [is->pictq_cond lock];
    while (is->pictq_size >= VIDEO_PICTURE_QUEUE_SIZE && !is->quit) {
        [is->pictq_cond wait];
    }
    [is->pictq_cond unlock];
    
    if (is->quit) {
        return -1;
    }
 
    [is->pictq_cond lock];
    vp = &is->pictq[is->pictq_windex];
    [is->pictq_cond unlock];
 
    if (!vp->pFrameYUV) {
        SDL_Event event;
        
        vp->allocated = 0;
        dispatch_sync(dispatch_get_main_queue(), ^{
            alloc_picture(is);
        });
 
        [is->pictq_cond lock];
        while (!vp->allocated && !is->quit) {
            [is->pictq_cond wait];
        }
        [is->pictq_cond unlock];
        if (is->quit) {
            return -1;
        }
    }
 
    if (vp->pFrameYUV) {
        vp->pts = pts;
        
//        由于解压缩帧不能直接用于SDL展示，因此需要对解压缩帧进行格式转换，pFrameYUV就是用来暂存格式转换后的临时对象。

//        由于AVFrame是一个对象，并非只包含解压缩帧的数据，还会包含一些其他数据,并且av_frame_alloc只是为pFrameYUV对象分配了内存，并没有为pFrameYUV对象中真正存储数据的对象分配内存，因此下面要对这个真正存储数据的对象分配内存。
        int numBytes = avpicture_get_size(AV_PIX_FMT_YUV420P, is->video_st->codec->width, is->video_st->codec->height);//得到这个帧的大小

        if (buffer == NULL) {
            buffer = (uint8_t*)av_malloc(numBytes*sizeof(uint8_t));//按照uint8_t分配内存，
        }

        avpicture_fill((AVPicture*)vp->pFrameYUV, buffer, AV_PIX_FMT_YUV420P, is->video_st->codec->width, is->video_st->codec->height);//将pFrameYUV中存储数据的对象与刚才分配的内存关联起来。

//         Convert the image into YUV format that SDL uses.
        sws_scale(is->sws_ctx, (uint8_t const * const *)pFrame->data, pFrame->linesize, 0, is->video_st->codec->height, vp->pFrameYUV->data, vp->pFrameYUV->linesize);

//         Now we inform our display thread that we have a pic ready.
        [is->pictq_cond lock];
        if (++is->pictq_windex == VIDEO_PICTURE_QUEUE_SIZE) {
            is->pictq_windex = 0;
        }
        
        is->pictq_size++;
        [is->pictq_cond unlock];
    }
    return 0;
}

int video_thread(void *arg) {
    VideoState *is = (VideoState *) arg;
    AVPacket pkt1, *packet = &pkt1;
    int frameFinished;
    AVFrame *pFrame;
    
    double pts;
    
    pFrame = av_frame_alloc();
    
    for (;;) {
        if (packet_queue_get(&is->videoq, packet, 1) < 0) {
  
            break;
        }
        pts = 0;
 

        avcodec_decode_video2(is->video_st->codec, pFrame, &frameFinished, packet);
        
        if (pFrame->best_effort_timestamp == AV_NOPTS_VALUE ){
            pts = 0;
        } else {
            pts = pFrame->best_effort_timestamp;
        }
        
        pts *= av_q2d(is->video_st->time_base);
        
        // Did we get a video frame?
        if (frameFinished) {
            pts = synchronize_video(is, pFrame, pts);
            if (queue_picture(is, pFrame,pts) < 0){
                break;
            }
        }
        av_packet_unref(packet);
    }
    av_frame_free(&pFrame);
    return 0;
}

int stream_component_open(VideoState *is, int stream_index) {
    
    AVFormatContext *pFormatCtx = is->pFormatCtx;
    AVCodecContext *codecCtx = NULL;
    AVCodec *codec = NULL;
    AVDictionary *optionsDict = NULL;
    SDL_AudioSpec wanted_spec, spec;
    
    if (stream_index < 0 || stream_index >= pFormatCtx->nb_streams) {
        return -1;
    }

    codecCtx = pFormatCtx->streams[stream_index]->codec;
    
    if (codecCtx->codec_type == AVMEDIA_TYPE_AUDIO) {
        wanted_spec.freq = codecCtx->sample_rate;
        wanted_spec.format = AUDIO_S16SYS;
        wanted_spec.channels = codecCtx->channels;
        wanted_spec.silence = 0;
        wanted_spec.samples = SDL_AUDIO_BUFFER_SIZE;
        wanted_spec.callback = audio_callback;
        wanted_spec.userdata = is;
        
        if (SDL_OpenAudio(&wanted_spec, &spec) < 0) {
            fprintf(stderr, "SDL_OpenAudio: %s\n", SDL_GetError());
            return -1;
        }
    }
    codec = avcodec_find_decoder(codecCtx->codec_id);
    if (!codec || (avcodec_open2(codecCtx, codec, &optionsDict) < 0)) {
        fprintf(stderr, "Unsupported codec!\n");
        return -1;
    }
    
    switch(codecCtx->codec_type) {
        case AVMEDIA_TYPE_AUDIO:
            is->audioStream = stream_index;
            is->audio_st = pFormatCtx->streams[stream_index];
            is->audio_buf_size = 0;
            is->audio_buf_index = 0;
            memset(&is->audio_pkt, 0, sizeof(is->audio_pkt));
            packet_queue_init(&is->audioq);
            SDL_PauseAudio(0);
            break;
        case AVMEDIA_TYPE_VIDEO:
            is->videoStream = stream_index;
            is->video_st = pFormatCtx->streams[stream_index];
            
            is->frame_timer = (double) av_gettime() / 1000000.0;
            is->frame_last_delay = 40e-3;
            
            dispatch_sync(dispatch_get_main_queue(), ^{
                bmp = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_IYUV, SDL_TEXTUREACCESS_STREAMING, is->video_st->codec->width, is->video_st->codec->height);//创建SDL_Texture对象，使用SDL_PIXELFORMAT_IYUV格式
            });
            packet_queue_init(&is->videoq);
            dispatch_async(dispatch_get_global_queue(0, 0), ^{
                video_thread(is);
            });
            is->sws_ctx = sws_getContext(is->video_st->codec->width, is->video_st->codec->height, is->video_st->codec->pix_fmt, is->video_st->codec->width, is->video_st->codec->height, AV_PIX_FMT_YUV420P, SWS_BILINEAR, NULL, NULL, NULL);
            break;
        default:
            break;
    }
    return 0;
}

int decode_interrupt_cb(void *opaque) {
    return (global_video_state && global_video_state->quit);
}

int stream_read(void *arg) {
    
    VideoState *is = (VideoState *)arg;
    AVFormatContext *pFormatCtx = NULL;
    AVPacket pkt1, *packet = &pkt1;
    
    int video_index = -1;
    int audio_index = -1;
    int i;
    
    AVDictionary *io_dict = NULL;
    AVIOInterruptCB callback;
    
    is->videoStream = -1;
    is->audioStream = -1;
    
    global_video_state = is;

    callback.callback = decode_interrupt_cb;
    callback.opaque = is;
    if (avio_open2(&is->io_context, is->filename, 0, &callback, &io_dict)) {
        fprintf(stderr, "Unable to open I/O for %s\n", is->filename);
        return -1;
    }
    

    if (avformat_open_input(&pFormatCtx, is->filename, NULL, NULL) != 0) {
        return -1;
    }
    
    is->pFormatCtx = pFormatCtx;
    
    if (avformat_find_stream_info(pFormatCtx, NULL)<0) {
        return -1;
    }

    av_dump_format(pFormatCtx, 0, is->filename, 0);
    
    for (i = 0; i < pFormatCtx->nb_streams; i++) {
        if (pFormatCtx->streams[i]->codec->codec_type==AVMEDIA_TYPE_VIDEO && video_index < 0) {
            video_index = i;
        }
        if (pFormatCtx->streams[i]->codec->codec_type==AVMEDIA_TYPE_AUDIO && audio_index < 0) {
            audio_index = i;
        }
    }
    if (audio_index >= 0) {
        stream_component_open(is, audio_index);
    }
    if (video_index >= 0) {
        stream_component_open(is, video_index);
    }
    
    if (is->videoStream < 0 || is->audioStream < 0) {
        fprintf(stderr, "%s: could not open codecs\n", is->filename);
        if (1) {
            SDL_Event event;
            event.type = FF_QUIT_EVENT;
            event.user.data1 = is;
            SDL_PushEvent(&event);
        }
        return 0;
    }

    for (;;) {
        if (is->quit) {
            break;
        }

        if (is->audioq.size > MAX_AUDIOQ_SIZE || is->videoq.size > MAX_VIDEOQ_SIZE) {
            SDL_Delay(10);
            continue;
        }
        if (av_read_frame(is->pFormatCtx, packet) < 0) {
            if (is->pFormatCtx->pb->error == 0) {
                SDL_Delay(100);
                continue;
            } else {
                break;
            }
        }
   
        if (packet->stream_index == is->videoStream) {
            packet_queue_put(&is->videoq, packet);
        } else if (packet->stream_index == is->audioStream) {
            packet_queue_put(&is->audioq, packet);
        } else {
            av_packet_unref(packet);
        }
    }

    while (!is->quit) {
        SDL_Delay(100);
    }
    return 0;
}

int main(int argc, char *argv[]) {
    
    SDL_Event event;
    
    VideoState *is;
    
    is = (VideoState *)av_mallocz(sizeof(VideoState));
    
    NSString * path = [[NSBundle  mainBundle]pathForResource:@"zidangyaliang.mp4" ofType:@""];//获取文件路径
  
    av_register_all();
    
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO | SDL_INIT_TIMER)) {
        fprintf(stderr, "Could not initialize SDL - %s\n", SDL_GetError());
        exit(1);
    }
    
    window = SDL_CreateWindow("", 0, 0, [UIScreen mainScreen].bounds.size.width, [UIScreen mainScreen].bounds.size.height, SDL_WINDOW_OPENGL|SDL_WINDOW_MAXIMIZED);//创建SDL_Window,类似于iOS中的UIWindow
    renderer = SDL_CreateRenderer(window, -1, 0);//创建SDL_Renderer
    
    av_strlcpy(is->filename, [path UTF8String], sizeof(is->filename));
    
    is->pictq_cond = [[NSCondition alloc] init];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.04 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        video_refresh_timer(is);
    });
    
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        stream_read(is);
    });
    for (;;) {
        SDL_WaitEvent(&event);
        switch(event.type) {
            case FF_QUIT_EVENT:
            case SDL_QUIT:
                is->quit = 1;
                [is->audioq.cond signal];
                [is->videoq.cond signal];
                SDL_Quit();
                return 0;
                break;
            default:
                break;
        }
    }
    return 0;
    
}
