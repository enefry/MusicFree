# Video artwork fixtures

`artwork-red.mp4` and `artwork-blue.mp4` are generated 64×64 solid-colour H.264 videos with silent AAC audio (0.2 seconds), with no attached picture. They verify that imported artwork comes from each video's actual pixels.

Generation command (substitute `red` or `blue`, and the corresponding album name):

```sh
ffmpeg -f lavfi -i color=c=red:s=64x64:d=0.2 -f lavfi -i anullsrc=r=44100:cl=mono -shortest -c:v libx264 -pix_fmt yuv420p -c:a aac -metadata album=Red artwork-red.mp4
```
