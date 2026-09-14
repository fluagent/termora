#include "terminal_pty_channel.h"
#include <windows.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <map>
#include <memory>
#include <mutex>
#include <thread>

namespace {
using flutter::EncodableList; using flutter::EncodableMap; using flutter::EncodableValue;
using Sink = flutter::EventSink<EncodableValue>;
std::wstring W(const std::string& s) { int n=MultiByteToWideChar(CP_UTF8,0,s.data(),(int)s.size(),0,0); std::wstring r(n,L'\0'); MultiByteToWideChar(CP_UTF8,0,s.data(),(int)s.size(),r.data(),n); return r; }
// cmd.exe must receive /C as a bare switch. Quote only arguments that actually
// need it; quoting every argument makes cmd treat its command tail incorrectly.
std::wstring Q(const std::wstring& s) {
  if (s.find_first_of(L" \t\"") == std::wstring::npos) return s;
  std::wstring result = L"\"";
  for (wchar_t c : s) {
    if (c == L'\"') result += L'\\';
    result += c;
  }
  return result + L"\"";
}
const EncodableValue* Get(const EncodableMap& m, const char* k) { auto i=m.find(EncodableValue(k)); return i==m.end()?nullptr:&i->second; }
std::string Str(const EncodableMap& m,const char* k) { auto v=Get(m,k); auto p=v?std::get_if<std::string>(v):nullptr; return p?*p:""; }
int Int(const EncodableMap& m,const char* k,int d) { auto v=Get(m,k); auto p=v?std::get_if<int32_t>(v):nullptr; return p?*p:d; }

class PtyChannel {
 public:
  explicit PtyChannel(flutter::BinaryMessenger* messenger, HWND window) : window_(window), methods_(messenger,"com.hxlive.termora/terminal_pty",&flutter::StandardMethodCodec::GetInstance()), events_(messenger,"com.hxlive.termora/terminal_pty/events",&flutter::StandardMethodCodec::GetInstance()) {
    methods_.SetMethodCallHandler([this](const auto& call, auto result) { Handle(call.method_name(), call.arguments(), std::move(result)); });
    events_.SetStreamHandler(std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
      [this](const EncodableValue*, std::unique_ptr<Sink> sink){ std::lock_guard<std::mutex> l(mu_); sink_=std::move(sink); return nullptr; },
      [this](const EncodableValue*){ std::lock_guard<std::mutex> l(mu_); sink_.reset(); return nullptr; }));
  }
 private:
  void Handle(const std::string& method,const EncodableValue* raw,std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    auto args=raw?std::get_if<EncodableMap>(raw):nullptr;
    if (!args) { result->Error("INVALID_ARGUMENTS","Missing arguments"); return; }
    if (method=="start") { Start(*args,std::move(result)); return; }
    int id=Int(*args,"sessionId",0); std::shared_ptr<Session> s; { std::lock_guard<std::mutex> l(mu_); auto i=sessions_.find(id); if(i!=sessions_.end()) s=i->second; }
    if(!s) { result->Error("SESSION_NOT_FOUND","PTY session not found"); return; }
    if(method=="write") s->Write(Str(*args,"input")); else if(method=="resize") s->Resize(Int(*args,"columns",120),Int(*args,"rows",32)); else if(method=="kill") s->Kill(); else { result->NotImplemented(); return; } result->Success();
  }
  class Session : public std::enable_shared_from_this<Session> {
   public:
    Session(int id, std::function<void(const char*,int,const std::string&)> emit) : id_(id),emit_(std::move(emit)) {}
    ~Session(){ Kill(); if(reader_.joinable())reader_.join(); if(waiter_.joinable())waiter_.join(); if(pty_)ClosePseudoConsole(pty_); if(in_)CloseHandle(in_); if(out_)CloseHandle(out_); if(process_)CloseHandle(process_); }
    bool Start(const EncodableMap& a) { SECURITY_ATTRIBUTES sa{sizeof(sa),0,TRUE}; HANDLE ir,ow; if(!CreatePipe(&ir,&in_,&sa,0)||!CreatePipe(&out_,&ow,&sa,0))return false; SetHandleInformation(in_,HANDLE_FLAG_INHERIT,0); SetHandleInformation(out_,HANDLE_FLAG_INHERIT,0); COORD size{(SHORT)Int(a,"columns",120),(SHORT)Int(a,"rows",32)}; if(FAILED(CreatePseudoConsole(size,ir,ow,0,&pty_)))return false; CloseHandle(ir);CloseHandle(ow); SIZE_T n=0; InitializeProcThreadAttributeList(0,1,0,&n); attrs_.resize(n); auto al=(LPPROC_THREAD_ATTRIBUTE_LIST)attrs_.data(); if(!InitializeProcThreadAttributeList(al,1,0,&n)||!UpdateProcThreadAttribute(al,0,PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,pty_,sizeof(pty_),0,0))return false; std::wstring cmd=Q(W(Str(a,"executable"))); if(auto list=Get(a,"arguments")){for(auto& v:*std::get_if<EncodableList>(list))cmd+=L" "+Q(W(*std::get_if<std::string>(&v)));} STARTUPINFOEXW si{};si.StartupInfo.cb=sizeof(si);si.lpAttributeList=al; PROCESS_INFORMATION pi{}; auto cwd=W(Str(a,"workingDirectory")); bool ok=CreateProcessW(0,cmd.data(),0,0,FALSE,EXTENDED_STARTUPINFO_PRESENT,0,cwd.empty()?0:cwd.c_str(),&si.StartupInfo,&pi); DeleteProcThreadAttributeList(al); if(!ok)return false; CloseHandle(pi.hThread);process_=pi.hProcess; reader_=std::thread([self=shared_from_this()]{self->Read();}); waiter_=std::thread([self=shared_from_this()]{WaitForSingleObject(self->process_,INFINITE);DWORD c;GetExitCodeProcess(self->process_,&c);self->emit_("exit",c,"");});return true; }
    void Write(const std::string& d){DWORD n;WriteFile(in_,d.data(),(DWORD)d.size(),&n,0);} void Resize(int c,int r){ResizePseudoConsole(pty_,COORD{(SHORT)c,(SHORT)r});} void Kill(){if(process_)TerminateProcess(process_,1);} 
   private: void Read(){char b[4096];DWORD n;while(ReadFile(out_,b,sizeof(b),&n,0)&&n)emit_("data",0,std::string(b,n));} int id_;HPCON pty_=0;HANDLE in_=0,out_=0,process_=0;std::vector<char>attrs_;std::thread reader_,waiter_;std::function<void(const char*,int,const std::string&)>emit_; };
  void Start(const EncodableMap& args,std::unique_ptr<flutter::MethodResult<EncodableValue>> result){ if(!GetProcAddress(GetModuleHandleW(L"kernel32.dll"),"CreatePseudoConsole")){result->Error("PTY_UNAVAILABLE","Windows ConPTY requires Windows 10 1809 or later");return;} int id=next_++; auto s=std::make_shared<Session>(id,[this,id](const char*t,int c,const std::string&d){Emit(t,id,c,d);}); if(!s->Start(args)){result->Error("PTY_START_FAILED","Could not start Windows ConPTY");return;} {std::lock_guard<std::mutex>l(mu_);sessions_[id]=s;} result->Success(EncodableValue(id)); }
  void Emit(const char*t,int id,int c,const std::string&d){auto e=new EncodableMap;e->operator[](EncodableValue("type"))=EncodableValue(t);e->operator[](EncodableValue("sessionId"))=EncodableValue(id);if(d.empty())e->operator[](EncodableValue("exitCode"))=EncodableValue(c);else e->operator[](EncodableValue("data"))=EncodableValue(d);if(!PostMessage(window_,kTerminalPtyEventMessage,0,reinterpret_cast<LPARAM>(e)))delete e;}
 public:
  void Deliver(EncodableMap* event){std::unique_ptr<EncodableMap> owned(event);std::lock_guard<std::mutex>l(mu_);if(sink_)sink_->Success(EncodableValue(*event));}
 private:
  HWND window_;std::mutex mu_;int next_=1;std::map<int,std::shared_ptr<Session>>sessions_;std::unique_ptr<Sink>sink_;flutter::MethodChannel<EncodableValue>methods_;flutter::EventChannel<EncodableValue>events_;
};
std::unique_ptr<PtyChannel> channel;
}
void RegisterTerminalPtyChannel(flutter::BinaryMessenger* messenger, HWND window){ channel=std::make_unique<PtyChannel>(messenger,window); }
bool HandleTerminalPtyWindowMessage(UINT message, LPARAM lparam){if(message!=kTerminalPtyEventMessage||!lparam)return false;if(channel)channel->Deliver(reinterpret_cast<EncodableMap*>(lparam));else delete reinterpret_cast<EncodableMap*>(lparam);return true;}
