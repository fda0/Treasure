3D game engine with networking. Video showcase:
[clip 4](https://www.youtube.com/watch?v=VxGE_yR9gus),
[clip 3](https://www.youtube.com/watch?v=QV_7TaHOlao),
[clip 2](https://www.youtube.com/watch?v=tm6N5Fy2Jxs),
[clip 1](https://www.youtube.com/watch?v=567seD6WJco),
[clip 0](https://www.youtube.com/watch?v=v2UXzL0xuF4)


# Cloning & building
```bash
git clone https://github.com/fda0/Treasure.git
git submodule update --init --recursive
```

Build the game, asset preprocessor, and libraries (cgltf, SDL DLLs):
```
jai compile.jai - build_all
```

Generate assets.pie file:
```
cd build
Baker.exe
```

Launch the game (starts a local server in the same process):
```
cd build
Treasure.exe -server -client
```


# Resources I found useful

## Collision
- [Collision Detection with SAT (Math for Game Developers) by pikuma](https://www.youtube.com/watch?v=-EsWKT7Doww)
- [N Tutorial A - Collision Detection and Response](https://www.metanetsoftware.com/2016/n-tutorial-a-collision-detection-and-response)

## Networking
- [Gaffer on Games](https://gafferongames.com/categories/game-networking/) - overview of common networking topics.

## Math
- [Handmade Math](https://github.com/HandmadeMath/HandmadeMath) - reference for matrix and quaternion implementations.
- [Quaternions, Double-cover, and the Rest Pose Neighborhood (2006) by Casey Muratori](https://caseymuratori.com/blog_0002) + [video](https://www.youtube.com/watch?v=vmAY5kP-tpU)
- [Understanding Slerp, Then Not Using It by Jonathan Blow](http://number-none.com/product/Understanding%20Slerp,%20Then%20Not%20Using%20It/)

## Models / animations
- https://github.com/jkuhlmann/cgltf - small, portable library that parses .gltf files into structs and arrays.
- [Skeletal animation in glTF - lisyarus blog](https://lisyarus.github.io/blog/posts/gltf-animation.html)

## Shadow mapping
- [Shadow maps, shadow volumes, deep shadow maps by Justin Solomon](https://www.youtube.com/watch?v=QCIKgyL3ePo) - MIT lecture overviewing shadow rendering techniques.
- [Shadow Mapping - learnopengl.com](https://learnopengl.com/Advanced-Lighting/Shadows/Shadow-Mapping) - step-by-step tutorial with common pitfalls explained.

## Outline rendering
- [The Quest for Very Wide Outlines](https://bgolus.medium.com/the-quest-for-very-wide-outlines-ba82ed442cd9) - overview of different techniques + introduction to jump flood algorithm.