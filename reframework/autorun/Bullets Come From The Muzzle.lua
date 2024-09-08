local statics = require("utility/Statics")
local re4 = require("utility/RE4")
--local WeaponService = require("Weapon Service")

re4.crosshair_pos = Vector3f.new(0, 0, 0)
re4.crosshair_normal = Vector3f.new(0, 0, 0)

local gameobject_get_transform = sdk.find_type_definition("via.GameObject"):get_method("get_Transform")
local cast_ray_async_method = sdk.find_type_definition("via.physics.System"):get_method("castRayAsync(via.physics.CastRayQuery, via.physics.CastRayResult)")

local joint_get_position = sdk.find_type_definition("via.Joint"):get_method("get_Position")
local joint_get_rotation = sdk.find_type_definition("via.Joint"):get_method("get_Rotation")

local CollisionLayer = statics.generate(sdk.game_namespace("CollisionUtil.Layer"))
local CollisionFilter = statics.generate(sdk.game_namespace("CollisionUtil.Filter"))

local crosshair_bullet_ray_result = nil
local crosshair_attack_ray_result = nil
local last_crosshair_time = os.clock()

local CLOSE_RANGE_THRESHOLD = 3.0
local CLOSE_RANGE_MODIFIER = 1.15 -- Modify bullets to hit 15% further at close range

local vec3_t = sdk.find_type_definition("via.vec3")
local quat_t = sdk.find_type_definition("via.Quaternion")
local raycastHit_t = sdk.find_type_definition(sdk.game_namespace("RaycastHit"))

 global_intersection_point = nil

-- Args: ctx, this, position, rotation
local function on_pre_request_fire(args)
  local shell_generator = sdk.to_managed_object(args[2])
  local arrow_shell_generator = sdk.to_managed_object(args[2])
  local gun = shell_generator:get_field("_OwnerInterface")
  local muzzle_joint = gun:call("getMuzzleJoint")
    if not muzzle_joint then
      
    end
  local owner = shell_generator:get_field("_Owner")
  local name = owner:call("get_Name")
  --log.info("Current weapon is " .. tostring(name))

  if name == "wp4005" then
    return
  end
  if name == "wp4402" then
    --return
  end

  if not muzzle_joint then
 --   log.warn("Initial Muzzle joint not found.")
    local gun_transforms = owner:get_Transform()
    
    -- Directly retrieve the "vfx_muzzle" joint using the getJointByName method
    muzzle_joint = gun_transforms:call("getJointByName", "vfx_muzzle")
    
    if muzzle_joint then
       -- log.info("Found vfx_muzzle")
    else
      --  log.warn("VFX Muzzle joint not found.")
    end
end

  if muzzle_joint ~= nil then
    local muzzle_pos = muzzle_joint:call("get_Position")
    local muzzle_rot = muzzle_joint:call("get_Rotation")
    local set_item = vec3_t:get_method("set_Item(System.Int32, System.Single)")
    local pos_addr = sdk.to_ptr(sdk.to_int64(args[3]))
    set_item:call(pos_addr, 0, muzzle_pos.x)
    set_item:call(pos_addr, 1, muzzle_pos.y)
    set_item:call(pos_addr, 2, muzzle_pos.z)

    if global_intersection_point then
      local direction_to_intersection = (global_intersection_point - muzzle_pos):normalized()

      local new_rotation = direction_to_intersection:to_quat()

      local set_item = quat_t:get_method("set_Item(System.Int32, System.Single)")
      local rot_addr = sdk.to_ptr(sdk.to_int64(args[4]))
      set_item:call(rot_addr, 0, new_rotation.x)
      set_item:call(rot_addr, 1, new_rotation.y)
      set_item:call(rot_addr, 2, new_rotation.z)
      set_item:call(rot_addr, 3, new_rotation.w)
    end
  end
end

local function on_post_request_fire(retval)
  return retval
end

local function hook_request_fire()
  local bullet_shell_generator_t = sdk.find_type_definition(sdk.game_namespace("BulletShellGenerator"))
  sdk.hook(bullet_shell_generator_t:get_method("requestFire"), on_pre_request_fire, on_post_request_fire)

  local shotgun_shell_generator_t = sdk.find_type_definition(sdk.game_namespace("ShotgunShellGenerator"))
  sdk.hook(shotgun_shell_generator_t:get_method("requestFire"), on_pre_request_fire, on_post_request_fire)
end

hook_request_fire()

local function cast_ray_async(ray_result, start_pos, end_pos, layer, filter_info)
  if layer == nil then
    layer = CollisionLayer.Bullet
  end

  local via_physics_system = sdk.get_native_singleton("via.physics.System")
  local ray_query = sdk.create_instance("via.physics.CastRayQuery")
  local ray_result = ray_result or sdk.create_instance("via.physics.CastRayResult")

  ray_query:call("setRay(via.vec3, via.vec3)", start_pos, end_pos)
  ray_query:call("clearOptions")
  ray_query:call("enableAllHits")
  ray_query:call("enableNearSort")

  if filter_info == nil then
    filter_info = ray_query:call("get_FilterInfo")
    filter_info:call("set_Group", 0)
    filter_info:call("set_MaskBits", 0xFFFFFFFF & ~1) -- everything except the player.
    filter_info:call("set_Layer", layer)
  end

  ray_query:call("set_FilterInfo", filter_info)
  cast_ray_async_method:call(via_physics_system, ray_query, ray_result)

  return ray_result
end

local function update_crosshair_world_pos(start_pos, end_pos)
  if crosshair_attack_ray_result == nil or crosshair_bullet_ray_result == nil then
    crosshair_attack_ray_result = cast_ray_async(crosshair_attack_ray_result, start_pos, end_pos, 5)
    crosshair_bullet_ray_result = cast_ray_async(crosshair_bullet_ray_result, start_pos, end_pos, 10)
    crosshair_attack_ray_result:add_ref()
    crosshair_bullet_ray_result:add_ref()
  end

  local finished = crosshair_attack_ray_result:call("get_Finished") == true and crosshair_bullet_ray_result:call("get_Finished")
  local attack_hit = finished and crosshair_attack_ray_result:call("get_NumContactPoints") > 0
  local any_hit = finished and (attack_hit or crosshair_bullet_ray_result:call("get_NumContactPoints") > 0)
  local both_hit = finished and crosshair_attack_ray_result:call("get_NumContactPoints") > 0 and crosshair_bullet_ray_result:call("get_NumContactPoints") > 0

  if finished and any_hit then
    local best_result = nil -- attack_hit and crosshair_attack_ray_result or crosshair_bullet_ray_result

    if both_hit then
      local attack_distance = crosshair_attack_ray_result:call("getContactPoint(System.UInt32)", 0):get_field("Distance")
      local bullet_distance = crosshair_bullet_ray_result:call("getContactPoint(System.UInt32)", 0):get_field("Distance")

      if attack_distance < bullet_distance then
        best_result = crosshair_attack_ray_result
      else
        best_result = crosshair_bullet_ray_result
      end
    else
      best_result = attack_hit and crosshair_attack_ray_result or crosshair_bullet_ray_result
    end

    local contact_point = best_result:call("getContactPoint(System.UInt32)", 0)


    if re4.crosshair_distance < CLOSE_RANGE_THRESHOLD then
      local corrective_scale = 0.01 -- adjust this value based on your needs
      local corrective_offset = Vector3f.new(-1, -1, 0) * corrective_scale
      re4.crosshair_dir = re4.crosshair_dir + corrective_offset
      re4.crosshair_dir = re4.crosshair_dir:normalized()
      re4.crosshair_pos = start_pos + (re4.crosshair_dir * re4.crosshair_distance * CLOSE_RANGE_MODIFIER)
  else
      re4.crosshair_pos = start_pos + (re4.crosshair_dir * re4.crosshair_distance * 1.0)
  end

    if contact_point then
      re4.crosshair_dir = (end_pos - start_pos):normalized()
      re4.crosshair_normal = contact_point:get_field("Normal")
      re4.crosshair_distance = contact_point:get_field("Distance")

      --log.info("Raycast distance: " .. tostring(re4.crosshair_distance))

    end
  else
    re4.crosshair_dir = (end_pos - start_pos):normalized()

    if re4.crosshair_distance then
      re4.crosshair_pos = start_pos + (re4.crosshair_dir * re4.crosshair_distance)
    else
      re4.crosshair_pos = start_pos + (re4.crosshair_dir * 10.0)
      re4.crosshair_distance = 10.0
    end
  end

  if finished then
    -- restart it.
    cast_ray_async(crosshair_attack_ray_result, start_pos, end_pos, 5, CollisionFilter.DamageCheckOtherThanPlayer)
    cast_ray_async(crosshair_bullet_ray_result, start_pos, end_pos, 10)
  end

  global_intersection_point = re4.crosshair_pos
end

re.on_pre_application_entry("LockScene", function()
  if re4.player == nil then
    return
  end
  if re4.body == nil then
    return
  end

  local camera = sdk.get_primary_camera()
  if not camera then
    print("no camera")
    return
  end

  local camera_gameobject = camera:call("get_GameObject")
  if not camera_gameobject then
    print("no gameobject")
    return
  end

  local camera_transform = gameobject_get_transform(camera_gameobject)
  if not camera_transform then
    print("no cam transform")
    return
  end

  local body_transform = re4.body:call("get_Transform")
  if not body_transform then
    print("no body transform")
    return
  end

  local camera_joint = camera_transform:call("get_Joints")[0]
  local camrot = joint_get_rotation(camera_joint)
  local cam_end = joint_get_position(camera_joint) + (camrot:to_mat4()[2] * -8192.0)

  update_crosshair_world_pos(joint_get_position(camera_joint), cam_end)
end)
