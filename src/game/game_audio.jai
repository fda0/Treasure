AUDIO_State :: struct
{
  device: SDL_AudioDeviceID;
  actives: [..] AUDIO_ActiveSound;
}

AUDIO_SoundType :: enum u32
{
  HIT;
  SWISH01;
  SWISH02;
  SWISH03;
  SWISH04;
  SWISH05;
}

AUDIO_Sound :: struct
{
  data: string;
  format: SDL_AudioSpec;
}

AUDIO_ActiveSound :: struct
{
  type: AUDIO_SoundType;
  start_time: Timestamp;
  duration: Timestamp;
  stream: *SDL_AudioStream;
}

AUDIO_Request :: struct
{
  tick: ServerTick;
  type: AUDIO_SoundType;
}

AUDIO_PlayObjectSounds :: ()
{
  INJECT("CL");
  assert(context.role == .CLIENT);

  for *ghost: CL.all_objects
  {
    if OBJ_HasAnyFlag(ghost.o, .PLAY_SOUNDS)
    {
      for sound: ghost.o.sound_requests
      {
        was_played := sound.tick < ghost.played_audio_tick;
        in_future := sound.tick > ghost.server_tick;
        if !was_played && !in_future
        {
          AUDIO_PlaySound(sound.type);
        }
      }
      ghost.played_audio_tick = ghost.server_tick;
    }
  }
}

AUDIO_PlaySound :: (sound_type: AUDIO_SoundType)
{
  if xx sound_type >= G.ast.sounds.count
  {
    log_error("Can't play missing sound %", sound_type);
    return;
  }

  sound := G.ast.sounds[sound_type];
  stream := SDL_CreateAudioStream(*sound.format, null);
  if stream == null
  {
    log_error("Failed to create audio stream");
    return;
  }

  SDL_BindAudioStream(G.audio.device, stream);
  SDL_PutAudioStreamData(stream, sound.data.data, xx sound.data.count);
  SDL_ResumeAudioStreamDevice(stream);
  SDL_FlushAudioStream(stream);

  format_bytesize := (sound.format.format & SDL_AUDIO_MASK_BITSIZE).(s32) / 8;
  duration_divisor := sound.format.freq * sound.format.channels * format_bytesize;

  active := AUDIO_ActiveSound.{
    type = sound_type,
    start_time = TimeNow(),
    duration = xx (sound.data.count*1000 / duration_divisor),
    stream = stream,
  };
  array_add(*G.audio.actives, active);
}

AUDIO_CloseFinishedStreams :: ()
{
  for G.audio.actives
  {
    if SDL_GetAudioStreamQueued(it.stream) == 0
    {
      SDL_DestroyAudioStream(it.stream);
      remove it;
    }
  }
}
