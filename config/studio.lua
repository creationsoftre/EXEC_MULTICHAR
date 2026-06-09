return {
  coords = vec3(-1107.6880, -1496.0933, 4.8295),
  heading = 149.5944,

  cams = {
    { label = 'Face',  offset = vec3(0.0, 1.6, 0.90), fov = 55.0, bone = 'head' },
    { label = 'Torso', offset = vec3(0.0, 2.1, 0.80), fov = 58.0 },
    { label = 'Full',  offset = vec3(0.0, 3.5, 1.00), fov = 60.0 }
  },

  smoothing = {
    enabled = true,
    positionLerp = 10.0,
    fovLerp = 12.0,
    snapDistance = 2.5,
  },

  pose = { enable = true, weapon = 'WEAPON_PISTOL' }
}
