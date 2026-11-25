#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <random>
#include "impeller/geometry/rect.h"

namespace impeller {
// EXACT_ENGINE_IMPL
}
using namespace impeller;

static void Require(bool value) {
  if (!value) {
    std::cerr << "Native dependency check failed." << std::endl;
    std::exit(1);
  }
}
int main() {
  std::mt19937 random(834709);
  std::uniform_real_distribution<float> unit(0.0f, 1.0f);
  auto u=[&]() { return unit(random); };
  int tested=0;
  for(int j=0;j<15000;j++) {
    int w=1+(random()%1024), h=1+(random()%1024);
    int rx=random()%65, ry=random()%65;
    float x0=(2*u()-.5f)*w, y0=(2*u()-.5f)*h;
    float x1=x0+.01f+u()*w, y1=y0+.01f+u()*h;
    float sx=.25f+16*u(),sy=.25f+16*u();
    const Matrix transform=Matrix::MakeTranslation({-1000+2000*u(),-1000+2000*u(),0})*
                          Matrix::MakeScale({sx,sy,1});
    const Rect output=Rect::MakeLTRB(x0,y0,x1,y1).TransformBounds(transform);
    const Rect inverse=output.TransformBounds(transform.Invert());
    const auto scissor=CalculateDownsampleScissor(output,transform,ISize(w,h),Vector2(rx,ry))
                           .value_or(IRect32::MakeLTRB(0,0,w,h));
    Require(scissor.GetLeft()>=0&&scissor.GetTop()>=0&&scissor.GetRight()<=w&&scissor.GetBottom()<=h);
    for(float px : {inverse.GetLeft(),inverse.GetRight(),inverse.GetLeft()+inverse.GetWidth()*u()}) {
      for(int base : {int(std::floor(px-.5f)),int(std::ceil(px-.5f))}) {
        for(int tap=-rx-1;tap<=rx+1;tap++) {
          int dependency=std::clamp(std::clamp(base,0,w-1)+tap,0,w-1);
          Require(dependency>=scissor.GetLeft()&&dependency<scissor.GetRight());
          tested++;
        }
      }
    }
    for(float py : {inverse.GetTop(),inverse.GetBottom(),inverse.GetTop()+inverse.GetHeight()*u()}) {
      for(int base : {int(std::floor(py-.5f)),int(std::ceil(py-.5f))}) {
        for(int tap=-ry-1;tap<=ry+1;tap++) {
          int dependency=std::clamp(std::clamp(base,0,h-1)+tap,0,h-1);
          Require(dependency>=scissor.GetTop()&&dependency<scissor.GetBottom());
          tested++;
        }
      }
    }
  }
  std::cout << "Native geometry: 15000 randomized transforms, " << tested
            << " clamped kernel taps passed." << std::endl;
}
