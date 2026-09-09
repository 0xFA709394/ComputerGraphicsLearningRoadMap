# 17 · Shader 模式库（Cookbook）

> 常用效果的最小可用实现，每条 5~20 行核心代码。用途：①练习素材（每个模式都是 03/04 章知识的组合题）②项目起步的积木。风格统一为 MSL/类 GLSL 伪代码。

---

## 1. 卡通着色（Toon/Cel Shading）

```cpp
// 量化光照 + 黑色描边
float ndl = dot(N, L);
float toon = floor(ndl * STEPS + 0.5) / STEPS;         // 阶梯化
float3 col = albedo * lightColor * toon;
// 高光硬边
float spec = step(0.9, powr(max(dot(N, H), 0), shininess)) * 0.8;
```
配套 rim（边缘光）：`float rim = 1 - saturate(dot(N, V)); col += rimColor * powr(rim, 3) * step(0.5, rim);`

## 2. 描边三法

```cpp
// A. 背面外壳法(vertex): 沿法线外扩——最简单, 硬边
out.pos = u.mvp * float4(pos + normal * OUTLINE_WIDTH * pos.w / viewport, 1);

// B. 后处理 sobel(屏幕): 需深度/法线 GBuffer
float d = length(float2(dFdx(depth), dFdy(depth)));   // 深度梯度
float edge = 1 - smoothstep(0.0, EDGE_T, d);           // 11章GBuffer复用

// C. 法线外扩+顶点色宽度(美术控制每部位描边粗细)
```

## 3. 玻璃（折射 + 菲涅尔 + 色散）

```cpp
// 1) 抓屏背景纹理(前一帧/同帧更早 pass)
float3 refrR = background.sample(s, uv + refract(-V, N, 1.0/iorR).xy * SCALE).rgb;
float3 refrG = background.sample(s, uv + refract(-V, N, 1.0/iorG).xy * SCALE).rgb;
float3 refrB = background.sample(s, uv + refract(-V, N, 1.0/iorB).xy * SCALE).rgb;
float3 refr = float3(refrR.r, refrG.g, refrB.b);       // RGB 微差折射率=色散
float F = F0 + (1-F0)*powr(1-max(dot(N,V),0), 5);
float3 col = mix(refr, reflectionProbe(N,V), F);       // 菲涅尔混合反射
```
升级：扰动法线（噪声流动）做毛玻璃；吸收 `exp(-absorb * thickness)` 做有色玻璃。

## 4. 水面简化版（两层法线 + 深度泡沫）

```cpp
// 法线滚动(04章噪声): 两层不同方向/速度叠加
float3 n1 = normalFromNoise(uv * 4 + t * 0.1);
float3 n2 = normalFromNoise(uv * 9 - t * 0.17);
float3 Nw = normalize(mix(n1, n2, 0.4));
// 深度渐变: 水深→颜色/透明度; 岸边泡沫
float depthDiff = sceneDepth - fragDepth;              // 11章 SSR 同款线性化
float foam = smoothstep(0.8, 0.0, depthDiff) * foamNoise(uv*30 + t);
float3 col = mix(shallowCol, deepCol, saturate(depthDiff*0.3));
col += foam;
// 反射: 菲涅尔加权(天空/探针), 折射: 抓屏偏移
```

## 5. 溶解效果（Dissolve）

```cpp
float n = fbm(uv * 20);                                // 04章噪声库
float clip = step(n, threshold); if (clip < 0.5) discard;   // 02章discard代价
float3 edge = emissive * smoothstep(threshold, threshold + 0.08, n); // 燃烧边
col = mix(burnColor, col, smoothstep(threshold+0.05, threshold+0.2, n)) + edge;
```
反式生长：threshold 从 1→0 即"从噪声里长出来"。

## 6. 全息/扫描线

```cpp
float scan = 0.5 + 0.5 * sin(worldPos.y * 80 - t * 4);          // 世界高度扫描
float grid = step(0.97, frac(worldPos.x*10)*frac(worldPos.y*10)); // 网格
float flicker = 0.9 + 0.1 * hash(floor(t*30));                   // 频闪
col = palColor * (scan*0.6 + grid) * flicker + rim * 2;          // +边缘光
alpha = 0.6;
```

## 7. 流动熔岩（Domain Warp）

```cpp
float2 p = uv * 3;
float w = fbm(p + t*0.1);              // 一次扭曲
float lava = fbm(p + w*2 + t*0.05);    // 二次采样(04章§D5)
float3 col = palette(lava);            // 黑→深红→橙→白 梯度
```

## 8. 皮肤简化（Wrap Lighting）

```cpp
// 包裹光照: 把 0 截断改成负值渐变(光"绕"过表面) —— SSS 的最便宜近似
float ndl = dot(N, L);
float wrap = (ndl + wrapFactor) / (1 + wrapFactor);    // wrapFactor≈0.5
float3 diffuse = albedo * saturate(wrap) * lightColor;
// + 曲率阴影(暗部偏红): shadowTint = mix(vec3(1), vec3(0.8,0.2,0.2), 1-ndl);
```
下一步升级：preintegrated skin（曲率贴图 BRDF 积分 LUT）——03 章专题的实现起点。

## 9. 毛发 Shell Fur（壳渲染概念）

```
N 个 pass, 每层沿法线抬升 h = layer/N, 采样同一张"毛发 alpha 高度图"
图测试: texAlpha(uv, layer/N) < noise → discard
层数 8~16: 假毛发但移动端便宜; 大世界用 hair card(11章)
```

## 10. 屏幕特效三件套（后处理）

```cpp
// 暗角
float vig = smoothstep(1.0, 0.3, length(uv - 0.5));
// 色差(径向 RGB 偏移)
float2 d = (uv - 0.5) * CA_AMOUNT;
float3 col = float3(tex(uv+d).r, tex(uv).g, tex(uv-d).b);
// 胶片颗粒(时间抖动)
col += (hash12(uv * 1000 + t) - 0.5) * GRAIN;
```

## 11. 调试视图 Shader（工程必备，10 章实践）

```cpp
// 法线可视化
return float4(N * 0.5 + 0.5, 1);
// UV 棋盘(检查插值/透视校正)
float2 c = floor(in.uv * 8); return float4(fmod(c.x+c.y, 2), 0, 0, 1);
// 热力图(标量→颜色)
float3 heat = paletteHeat(v);   // 蓝→绿→红 渐变函数
// 线框(步进重心坐标)
float3 b = abs(bary - 0.5); float wire = step(min3(b), 0.02); ...
```

## 12. 综合练习题

1. 把 1+2 组合成"动画渲染风格"角色（卡通光照+背面描边+rim），参数面板化控制阶梯数/描边宽。
2. 把 4 扩展成真 Gerstner 波位移（顶点位移+法线解析），对比噪声法线的观感差异。
3. 用 11 的调试视图排查一次"光照诡异"：依次输出 N/V/L/H 向量截图，定位哪个量错了——**调试视图是渲染工程师最被低估的生产力工具**。
