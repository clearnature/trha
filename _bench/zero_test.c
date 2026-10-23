/* 验证：x 输入含 0（值域 0..8）vs 全非零（3..21）是否造成 15 倍差 */
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
  int32_t *w=malloc(sizeof(int32_t)*rows*cols), *xa=malloc(sizeof(int32_t)*cols), *xb=malloc(sizeof(int32_t)*cols), *out=malloc(sizeof(int32_t)*rows);
  for (int i=0;i<rows*cols;i++) w[i]=i%3;
  for (int i=0;i<cols;i++) xa[i]=i%9;               /* 0..8，含零（像 christoffel 输出） */
  for (int i=0;i<cols;i++) xb[i]=3+(i%18);          /* 3..20，全非零（像常量表） */
  trha_gf27_matmul_table(out,w,xa,rows,cols,logT,expT);
  trha_gf27_matmul_table(out,w,xb,rows,cols,logT,expT);
  double t0=now(); for(int k=0;k<30;k++) trha_gf27_matmul_table(out,w,xa,rows,cols,logT,expT); double t1=now();
  double t2=now(); for(int k=0;k<30;k++) trha_gf27_matmul_table(out,w,xb,rows,cols,logT,expT); double t3=now();
  printf("x=0..8（含零）: %.3f ms/轮\n", (t1-t0)*1000/30);
  printf("x=3..20（非零）: %.3f ms/轮\n", (t3-t2)*1000/30);
  return 0;
}
