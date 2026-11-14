// Disposable GPU-only frozen-desktop optics probe, not product code.
#include <dxgi1_2.h>
#include <d3dcompiler.h>
#include <algorithm>
#include <cstring>

HWND CreateControlledDesktop(const RECT& bounds) {
  HWND pattern=CreateWindowExW(WS_EX_TOPMOST|WS_EX_TOOLWINDOW,L"STATIC",L"Controlled desktop optics source",
      WS_POPUP,bounds.left,bounds.top,bounds.right-bounds.left,bounds.bottom-bounds.top,
      nullptr,nullptr,GetModuleHandleW(nullptr),nullptr);
  if (!pattern) throw std::runtime_error("Controlled desktop window failed");
  ShowWindow(pattern,SW_SHOWNOACTIVATE);
  const int width=bounds.right-bounds.left,height=bounds.bottom-bounds.top;
  std::vector<uint32_t> pixels(width*height);
  for (int y=0;y<height;++y) for (int x=0;x<width;++x)
    pixels[y*width+x]=((x/16+y/16)&1)?0xffe030a0:0xff20c050;
  BITMAPINFO bitmap{};bitmap.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
  bitmap.bmiHeader.biWidth=width;bitmap.bmiHeader.biHeight=-height;
  bitmap.bmiHeader.biPlanes=1;bitmap.bmiHeader.biBitCount=32;bitmap.bmiHeader.biCompression=BI_RGB;
  HDC dc=GetDC(pattern);
  const int copied=SetDIBitsToDevice(dc,0,0,width,height,0,0,0,height,pixels.data(),&bitmap,DIB_RGB_COLORS);
  ReleaseDC(pattern,dc);
  if (!copied) { DestroyWindow(pattern);throw std::runtime_error("Controlled desktop upload failed"); }
  Check(DwmFlush(),"Controlled desktop DwmFlush");
  return pattern;
}

class NativeRefraction {
  ComPtr<ID3D11Texture2D> snapshot;
  ComPtr<ID3D11ShaderResourceView> source;
  ComPtr<ID3D11VertexShader> vertex;
  ComPtr<ID3D11PixelShader> pixel;
  ComPtr<ID3D11Buffer> constants;
  ComPtr<ID3D11SamplerState> sampler;
  ID3D11Device* device;
  ID3D11DeviceContext* context;
  RECT output{};
  UINT width=0,height=0;
  struct Parameters { float capture[4],placement[4],mode[4]; };
 public:
  NativeRefraction(ID3D11Device* gpu,ID3D11DeviceContext* immediate,HWND host,FILE* log)
      :device(gpu),context(immediate) {
    ComPtr<IDXGIDevice> dxgi;Check(device->QueryInterface(IID_PPV_ARGS(&dxgi)),"snapshot DXGI");
    ComPtr<IDXGIAdapter> adapter;Check(dxgi->GetAdapter(&adapter),"snapshot adapter");
    ComPtr<IDXGIOutputDuplication> duplication;
    const HMONITOR monitor=MonitorFromWindow(host,MONITOR_DEFAULTTONEAREST);
    for (UINT index=0;;++index) {
      ComPtr<IDXGIOutput> candidate;
      if (adapter->EnumOutputs(index,&candidate)==DXGI_ERROR_NOT_FOUND) break;
      DXGI_OUTPUT_DESC desc{};Check(candidate->GetDesc(&desc),"snapshot output desc");
      if (desc.Monitor!=monitor) continue;
      if (desc.Rotation!=DXGI_MODE_ROTATION_IDENTITY) throw std::runtime_error("Rotated output not covered by this probe");
      output=desc.DesktopCoordinates;
      ComPtr<IDXGIOutput1> output1;Check(candidate.As(&output1),"snapshot output1");
      Check(output1->DuplicateOutput(device,&duplication),"snapshot DuplicateOutput");break;
    }
    if (!duplication) throw std::runtime_error("Snapshot output unavailable on selected GPU");
    DXGI_OUTDUPL_FRAME_INFO frame{};ComPtr<IDXGIResource> resource;
    Check(duplication->AcquireNextFrame(2000,&frame,&resource),"snapshot AcquireNextFrame");
    ComPtr<ID3D11Texture2D> acquired;Check(resource.As(&acquired),"snapshot texture");
    D3D11_TEXTURE2D_DESC desc{};acquired->GetDesc(&desc);width=desc.Width;height=desc.Height;
    desc.Usage=D3D11_USAGE_DEFAULT;desc.CPUAccessFlags=0;desc.MiscFlags=0;
    desc.BindFlags=D3D11_BIND_SHADER_RESOURCE;
    Check(device->CreateTexture2D(&desc,nullptr,&snapshot),"snapshot copy texture");
    context->CopyResource(snapshot.Get(),acquired.Get());
    Check(duplication->ReleaseFrame(),"snapshot ReleaseFrame");
    Check(device->CreateShaderResourceView(snapshot.Get(),nullptr,&source),"snapshot SRV");
    std::fprintf(log,"frozen_desktop qpc=%lld output=%ld,%ld,%ld,%ld dimensions=%u,%u format=%u protected_masked=%d desktop_present=%lld saved_image=0\n",
        Qpc(),output.left,output.top,output.right,output.bottom,width,height,desc.Format,
        frame.ProtectedContentMaskedOut,frame.LastPresentTime.QuadPart);

    const char* shader=R"hlsl(
Texture2D desktop : register(t0);
SamplerState linearClamp : register(s0);
cbuffer Params : register(b0) { float4 capture; float4 placement; float4 mode; };
float4 vs(uint id:SV_VertexID):SV_POSITION {
  float2 uv=float2((id<<1)&2,id&2);
  return float4(uv*float2(2,-2)+float2(-1,1),0,1);
}
float4 sampleBackdrop(float2 world) {
  float4 c=desktop.SampleLevel(linearClamp,saturate((world-capture.zw)/capture.xy),0);
  float l=dot(c.rgb,float3(.213,.715,.072));
  return float4(saturate(l+(c.rgb-l)*1.25),1);
}
float4 ps(float4 position:SV_POSITION):SV_TARGET {
  float2 local=position.xy-placement.zw;
  float2 halfSize=float2(324,200),centered=local-halfSize;
  float radius=36;
  float2 q=abs(centered)-(halfSize-radius);
  float sd=length(max(q,0))-radius+min(max(q.x,q.y),0);
  if (sd>.5) return 0;
  // Position and sequence tags bypass optics only in these two narrow bands.
  if (mode.w>0 && local.y>=100 && local.y<128) {
    uint value=local.y<116 ? uint(placement.x) : uint(mode.z);
    uint bit=min(uint(local.x/54),11);
    return ((value>>bit)&1) ? float4(0,1,0,1) : float4(1,0,1,1);
  }
  float2 world=placement.xy+local;
  float4 color=sampleBackdrop(world);
  if (-sd<24 && mode.x!=0) {
    float t=saturate(1-(-min(sd,0))/24);
    float distance=(1-sqrt(1-t*t))*mode.x;
    float gradRadius=min(radius*1.5,min(halfSize.x,halfSize.y));
    float2 corner=abs(centered)-(halfSize-gradRadius),gradient;
    if (corner.x>=0 || corner.y>=0) {
      float2 normal=max(corner,0);
      gradient=sign(centered)*normal/max(length(normal),1e-6);
    } else {
      float gx=step(corner.y,corner.x);gradient=sign(centered)*float2(gx,1-gx);
    }
    float2 sum=gradient+centered/max(length(centered),1e-6);
    if (length(sum)>1e-6) gradient=normalize(sum);
    float2 refracted=world+distance*gradient;
    if (mode.y>0) {
      float2 spread=distance*gradient*mode.y*centered.x*centered.y/(halfSize.x*halfSize.y);
      float4 r=sampleBackdrop(refracted+spread);
      float4 o=sampleBackdrop(refracted+spread*(2./3.));
      float4 y=sampleBackdrop(refracted+spread*(1./3.));
      float4 g=sampleBackdrop(refracted);
      float4 c=sampleBackdrop(refracted-spread*(1./3.));
      float4 b=sampleBackdrop(refracted-spread*(2./3.));
      float4 p=sampleBackdrop(refracted-spread);
      color=float4((r.r+o.r+y.r)/3.5+p.r/7,
          o.g/7+(y.g+g.g+c.g)/3.5,(c.b+b.b+p.b)/3,1);
    } else color=sampleBackdrop(refracted);
  }
  return float4(saturate(color.rgb),1)*(1-smoothstep(-.5,.5,sd));
}
)hlsl";
    ComPtr<ID3DBlob> vs,ps,errors;
    HRESULT hr=D3DCompile(shader,std::strlen(shader),nullptr,nullptr,nullptr,"vs","vs_5_0",D3DCOMPILE_OPTIMIZATION_LEVEL3,0,&vs,&errors);
    if (FAILED(hr) && errors) std::fprintf(log,"shader_error %s\n",static_cast<char*>(errors->GetBufferPointer()));
    Check(hr,"compile native VS");errors.Reset();
    hr=D3DCompile(shader,std::strlen(shader),nullptr,nullptr,nullptr,"ps","ps_5_0",D3DCOMPILE_OPTIMIZATION_LEVEL3,0,&ps,&errors);
    if (FAILED(hr) && errors) std::fprintf(log,"shader_error %s\n",static_cast<char*>(errors->GetBufferPointer()));
    Check(hr,"compile native PS");
    Check(device->CreateVertexShader(vs->GetBufferPointer(),vs->GetBufferSize(),nullptr,&vertex),"native VS");
    Check(device->CreatePixelShader(ps->GetBufferPointer(),ps->GetBufferSize(),nullptr,&pixel),"native PS");
    D3D11_BUFFER_DESC buffer{};buffer.ByteWidth=sizeof(Parameters);buffer.Usage=D3D11_USAGE_DEFAULT;buffer.BindFlags=D3D11_BIND_CONSTANT_BUFFER;
    Check(device->CreateBuffer(&buffer,nullptr,&constants),"native params");
    D3D11_SAMPLER_DESC sampling{};sampling.Filter=D3D11_FILTER_MIN_MAG_MIP_LINEAR;
    sampling.AddressU=sampling.AddressV=sampling.AddressW=D3D11_TEXTURE_ADDRESS_CLAMP;sampling.MaxLOD=D3D11_FLOAT32_MAX;
    Check(device->CreateSamplerState(&sampling,&sampler),"native sampler");
  }
  void CopyHost(IDCompositionSurface* surface,const RECT& host) {
    if (host.left<output.left || host.top<output.top || host.right>output.right || host.bottom>output.bottom)
      throw std::runtime_error("Frozen host crosses output boundary");
    ComPtr<IDXGISurface> update;POINT offset{};
    Check(surface->BeginDraw(nullptr,IID_PPV_ARGS(&update),&offset),"root snapshot BeginDraw");
    ComPtr<ID3D11Texture2D> texture;Check(update.As(&texture),"root snapshot texture");
    D3D11_BOX box{UINT(host.left-output.left),UINT(host.top-output.top),0,
        UINT(host.right-output.left),UINT(host.bottom-output.top),1};
    context->CopySubresourceRegion(texture.Get(),0,offset.x,offset.y,0,snapshot.Get(),0,&box);
    texture.Reset();update.Reset();Check(surface->EndDraw(),"root snapshot EndDraw");
  }
  void DrawTexture(ID3D11Texture2D* texture,POINT offset,int x,int y,unsigned seq,float amount,bool tags) {
    ComPtr<ID3D11RenderTargetView> target;Check(device->CreateRenderTargetView(texture,nullptr,&target),"native target view");
    Parameters data{{float(width),float(height),float(output.left),float(output.top)},
        {float(x),float(y),float(offset.x),float(offset.y)},{amount,.3f,float(seq),tags?1.f:0.f}};
    context->UpdateSubresource(constants.Get(),0,nullptr,&data,0,0);
    D3D11_VIEWPORT viewport{float(offset.x),float(offset.y),float(kCardWidth),float(kCardHeight),0,1};
    context->RSSetViewports(1,&viewport);
    ID3D11RenderTargetView* rt=target.Get();context->OMSetRenderTargets(1,&rt,nullptr);
    context->OMSetBlendState(nullptr,nullptr,0xffffffff);context->IASetInputLayout(nullptr);
    context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    context->VSSetShader(vertex.Get(),nullptr,0);context->PSSetShader(pixel.Get(),nullptr,0);
    ID3D11ShaderResourceView* srv=source.Get();context->PSSetShaderResources(0,1,&srv);
    ID3D11SamplerState* state=sampler.Get();context->PSSetSamplers(0,1,&state);
    ID3D11Buffer* cb=constants.Get();context->PSSetConstantBuffers(0,1,&cb);
    context->Draw(3,0);context->OMSetRenderTargets(0,nullptr,nullptr);
    srv=nullptr;context->PSSetShaderResources(0,1,&srv);
  }
  void Render(IDCompositionSurface* surface,int x,int y,unsigned seq) {
    ComPtr<IDXGISurface> update;POINT offset{};
    Check(surface->BeginDraw(nullptr,IID_PPV_ARGS(&update),&offset),"lens BeginDraw");
    ComPtr<ID3D11Texture2D> texture;Check(update.As(&texture),"lens texture");
    DrawTexture(texture.Get(),offset,x,y,seq,-45.2f,true);
    texture.Reset();update.Reset();Check(surface->EndDraw(),"lens EndDraw");
  }
  void CheckOptics(int x,int y,FILE* log,bool synthetic=false) {
    ComPtr<ID3D11ShaderResourceView> saved_source=source;
    if (synthetic) {
      std::vector<uint32_t> checker(width*height);
      for (UINT y=0;y<height;++y) for (UINT x=0;x<width;++x)
        checker[y*width+x]=((x/16+y/16)&1)?0xffe030a0:0xff20c050;
      D3D11_TEXTURE2D_DESC pattern{};pattern.Width=width;pattern.Height=height;
      pattern.MipLevels=pattern.ArraySize=pattern.SampleDesc.Count=1;
      pattern.Format=DXGI_FORMAT_B8G8R8A8_UNORM;pattern.Usage=D3D11_USAGE_DEFAULT;pattern.BindFlags=D3D11_BIND_SHADER_RESOURCE;
      D3D11_SUBRESOURCE_DATA initial{checker.data(),width*4,0};ComPtr<ID3D11Texture2D> texture;
      Check(device->CreateTexture2D(&pattern,&initial,&texture),"optics pattern texture");
      source.Reset();Check(device->CreateShaderResourceView(texture.Get(),nullptr,&source),"optics pattern SRV");
    }
    D3D11_TEXTURE2D_DESC desc{};desc.Width=kCardWidth;desc.Height=kCardHeight;
    desc.MipLevels=desc.ArraySize=desc.SampleDesc.Count=1;desc.Format=DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.Usage=D3D11_USAGE_DEFAULT;desc.BindFlags=D3D11_BIND_RENDER_TARGET;
    ComPtr<ID3D11Texture2D> a,b,ra,rb;
    Check(device->CreateTexture2D(&desc,nullptr,&a),"optics a");Check(device->CreateTexture2D(&desc,nullptr,&b),"optics b");
    desc.BindFlags=0;desc.Usage=D3D11_USAGE_STAGING;desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
    Check(device->CreateTexture2D(&desc,nullptr,&ra),"optics staging a");Check(device->CreateTexture2D(&desc,nullptr,&rb),"optics staging b");
    DrawTexture(a.Get(),{},x,y,0,0,false);DrawTexture(b.Get(),{},x,y,0,-45.2f,false);
    context->CopyResource(ra.Get(),a.Get());context->CopyResource(rb.Get(),b.Get());
    D3D11_MAPPED_SUBRESOURCE ma{},mb{};
    Check(context->Map(ra.Get(),0,D3D11_MAP_READ,0,&ma),"optics map a");Check(context->Map(rb.Get(),0,D3D11_MAP_READ,0,&mb),"optics map b");
    unsigned changed=0,max_delta=0,alpha_bad=0,visible=0,min_rgb=0xffffff,max_rgb=0;
    for (int row=0;row<kCardHeight;++row) for (int col=0;col<kCardWidth;++col) {
      const auto* pa=static_cast<uint8_t*>(ma.pData)+row*ma.RowPitch+col*4;
      const auto* pb=static_cast<uint8_t*>(mb.pData)+row*mb.RowPitch+col*4;
      unsigned delta=0;for (int channel=0;channel<3;++channel) delta=std::max(delta,unsigned(std::abs(int(pa[channel])-pb[channel])));
      if (delta>1) ++changed;max_delta=std::max(max_delta,delta);
      if (pb[3]) ++visible;
      if (pa[3]==255) {
        const unsigned rgb=(pa[2]<<16)|(pa[1]<<8)|pa[0];
        min_rgb=std::min(min_rgb,rgb);max_rgb=std::max(max_rgb,rgb);
      }
      if (pb[0]>pb[3] || pb[1]>pb[3] || pb[2]>pb[3]) ++alpha_bad;
    }
    const auto* corner=static_cast<uint8_t*>(mb.pData);
    std::fprintf(log,"optics_control qpc=%lld input=%s changed_pixels=%u max_rgb_delta=%u visible_pixels=%u flat_rgb_min=%06X flat_rgb_max=%06X invalid_premult=%u corner_alpha=%u refraction=45.2 chromatic=.3 blur=none\n",
        Qpc(),synthetic?"checker":"frozen_desktop",changed,max_delta,visible,min_rgb,max_rgb,alpha_bad,corner[3]);
    context->Unmap(ra.Get(),0);context->Unmap(rb.Get(),0);
    source=saved_source;
  }
};
