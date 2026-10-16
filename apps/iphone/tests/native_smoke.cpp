#include "../KernalMobile/Native/KMLlama.h"
#include <cassert>
#include <cstring>
#include <iostream>
#include <string>
int main(int argc,char **argv) {
    assert(argc==5);
    char error[512]={};char output[4096]={};
    assert(km_available_memory_bytes()>0);
    assert(km_engine_create(nullptr,2,2ULL<<30,error,sizeof(error))==nullptr);
    assert(error[0]);
    assert(km_engine_create(argv[1],2,1024,error,sizeof(error))==nullptr);
    assert(error[0]);
    assert(km_engine_create(argv[1],2,2ULL<<30,error,sizeof(error))==nullptr);
    assert(std::strstr(error,"template"));
    assert(km_engine_create(argv[3],2,2ULL<<30,error,sizeof(error))==nullptr);
    assert(std::strstr(error,"full native context"));
    assert(km_engine_create(argv[4],2,2ULL<<30,error,sizeof(error))==nullptr);
    assert(std::strstr(error,"memory budget"));
    km_engine *engine=km_engine_create(argv[2],2,2ULL<<30,error,sizeof(error));
    if(!engine){std::cerr<<error<<"\n";return 2;}
    assert(km_engine_native_context(engine)==2048);
    assert(km_engine_model_size(engine)>1000000);
    km_chat_message message{"user","Once upon a time"};
    km_engine_reset_cancel(engine);
    int result=km_engine_generate(engine,&message,1,8,output,sizeof(output),error,sizeof(error));
    if(result){std::cerr<<error<<"\n";return 3;}
    assert(output[0]);
    const size_t generated=std::strlen(output);
    km_engine_reset_cancel(engine);km_engine_cancel(engine);output[0]='x';
    assert(km_engine_generate(engine,&message,1,8,output,sizeof(output),error,sizeof(error))==1);
    assert(output[0]=='\0');
    km_engine_reset_cancel(engine);
    std::string long_text(16000,'x');message.content=long_text.c_str();
    assert(km_engine_generate(engine,&message,1,8,output,sizeof(output),error,sizeof(error))<0);
    assert(std::strstr(error,"native context"));assert(output[0]=='\0');
    message.content="<s>";
    assert(km_engine_generate(engine,&message,1,8,output,sizeof(output),error,sizeof(error))<0);
    assert(std::strstr(error,"control tokens"));
    message.content="Once upon a time";
    assert(km_engine_generate(engine,&message,1,0,output,sizeof(output),error,sizeof(error))<0);
    assert(km_engine_generate(engine,&message,1,8,output,1,error,sizeof(error))<0);
    km_engine_reset_cancel(engine);
    assert(km_engine_generate(engine,&message,1,8,output,sizeof(output),error,sizeof(error))==0);
    km_engine_destroy(engine);
    std::cout<<"PASS native-context=2048 generated-bytes="<<generated<<" checks=14\n";
}
