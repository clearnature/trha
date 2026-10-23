#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <omp.h>
int trha_gf27_matmul_table(int32_t*, const int32_t*, const int32_t*, int32_t, int32_t, const int32_t*, const int32_t*);
static int32_t logT[27] = {-1,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25};
static int32_t expT[27] = {0,1,2,3,5,15,23,13,17,20,4,12,14,11,2,6,18,7,21,16,26,22,10,8,24,25,19};
static double now(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec+t.tv_nsec*1e-9; }
int main(void){
  omp_set_num_threads(18);
  int rows=1440, cols=1440;
  int32_t *w=malloc(sizeof(int32_t)*rows*cols), *x=malloc(sizeof(int32_t)*cols), *out=malloc(sizeof(int32_t)*rows);
  for (int i=0;i<rows*cols;i++) w[i]=i%3;
  for (int i=0;i<cols;i++) x[i]=i%27;
  trha_gf27_matmul_table(out,w,x,rows,cols,logT,expT);
  double t0=now(); for(int k=0;k<30;k++) trha_gf27_matmul_table(out,w,x,rows,cols,logT,expT); double t1=now();
  printf("A 同指针 30 轮 = %.3f ms/轮\n", (t1-t0)*1000/30);
  int32_t *w2=malloc(sizeof(int32_t)*rows*cols);
  double t2=now(); for(int k=0;k<30;k++){ memcpy(w2,w,sizeof(int32_t)*rows*cols); trha_gf27_matmul_table(out,w2,x,rows,cols,logT,expT);} double t3=now();
  printf("B 每轮拷 2M int32 + matmul = %.3f ms/轮\n", (t3-t2)*1000/30);
  return 0;
}
