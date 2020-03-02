
local script_data =
{
  drones = {}
}

local transport_drone = {}

transport_drone.metatable = {__index = transport_drone}

local add_drone = function(drone)
  script_data.drones[drone.index] = drone
end

local remove_drone = function(drone)
  script_data.drones[drone.index] = nil
end

local get_drone = function(index)

  local drone = script_data.drones[index]
  
  if not drone then
    return
  end

  if not drone.entity.valid then
    drone:clear_things(index)
    return
  end

  return drone

end

local get_drone_mining_speed = function()
  return 0.5
end

local mining_times = {}
local get_mining_time = function(entity)

  local name = entity.name
  local time = mining_times[name]
  if time then return time end

  time = entity.prototype.mineable_properties.mining_time
  mining_times[name] = time
  return time

end

local interval = shared.mining_interval
local damage = shared.mining_damage
local ceil = math.ceil
local max = math.max
local min = math.min

local proxy_names = {}
local get_proxy_name = function(entity)

  local entity_name = entity.name
  local proxy_name = proxy_names[entity_name]
  if proxy_name then
    return proxy_name
  end

  if game.entity_prototypes[shared.attack_proxy_name..entity.name] then
    proxy_name = shared.attack_proxy_name..entity.name
  else
    local size = min(ceil((max(entity.get_radius() - 0.1, 0.25)) * 2), 10)
    proxy_name = shared.attack_proxy_name..size
  end

  proxy_names[entity_name] = proxy_name

  return proxy_name

end


local states =
{
  going_to_supply = 1,
  return_to_requester = 2
}

local random = math.random
local product_amount = function(product)

  if product.probability < 1 and random() >= product.probability then
    return 0
  end

  if product.amount then
    return product.amount
  end

  return random(product.amount_min, product.amount_max)

end


transport_drone.new = function(request_depot, supply_depot, requested_name, requested_count)

  local entity = request_depot.corpse.surface.create_entity{name = "transport-drone", position = request_depot.corpse.position, force = request_depot.entity.force}
  
  local drone =
  {
    entity = entity,
    request_depot = request_depot,
    supply_depot = supply_depot,
    requested_name = requested_name,
    requested_count = requested_count,
    index = tostring(entity.unit_number),
    state = states.going_to_supply
  }

  entity.ai_settings.path_resolution_modifier = 0
  entity.speed = (entity.speed + (math.random() * 0.01)) * 0.5
  
  setmetatable(drone, transport_drone.metatable)

  add_drone(drone)

  entity.set_command
  {
    type = defines.command.go_to_location,
    destination_entity = supply_depot.corpse,
    distraction = defines.distraction.none,
    radius = 0.5,
    pathfind_flags = {prefer_straight_paths = false, use_cache = false}
  }

  return drone
end

function transport_drone:spill(stack)
  self.entity.surface.spill_item_stack(self.entity.position, stack, false, nil, false)
end

local max = math.max
local random = math.random
function transport_drone:process_mining()

  local target = self.mining_target
  if not (target and target.valid) then
    --cancel command or something.
    return self:return_to_depot()
  end


  local item = self.depot.item
  if not item then
    --self:say("I don't know what I want")
    self:return_to_depot()
    return
  end

  local item_flow = self.entity.force.item_production_statistics.on_flow

  if target.type == "item-entity" then

    local stack = target.stack
    if stack.name == item then
      self.stack = {name = stack.name, count = stack.count}
      item_flow(item, stack.count)
    else
      self:spill{name = stack.name, count = stack.count}
    end

  else

    local pollute = self.entity.surface.pollute
    local pollution_flow = game.pollution_statistics.on_flow

    local productivity_bonus_chance = self:get_productivity_probability()
    local bonus_amount = 0
    if productivity_bonus_chance > 0 then
      for k = 1, self.mining_count do
        local chance = productivity_bonus_chance
        while chance > 0 do
          if random() < productivity_bonus_chance then
            bonus_amount = bonus_amount + 1
          end
          chance = chance - 1
        end
      end
    end

    for k, product in pairs (get_products(target)) do
      local count = product_amount(product) * self.mining_count
      if count > 0 then
        pollute(target.position, pollution_per_ore * count)
        pollution_flow(default_bot_name, pollution_per_ore * count)

        local count = count + bonus_amount

        if product.name == item then
          self.stack = {name = product.name, count = count}
          item_flow(item, count)
        else
          self:spill{name = product.name, count = count}
        end

      end
    end

  end

  if target.type == "resource" then
    local resource_amount = target.amount
    if target.initial_amount then
      --It is infinite
      target.amount = max(resource_amount - self.mining_count, target.prototype.minimum_resource_amount)
    elseif resource_amount > self.mining_count then
        target.amount = resource_amount - self.mining_count
    else
      self:clear_mining_target()
      script.raise_event(defines.events.on_resource_depleted, {entity = target})
      target.destroy()
    end
  else
    self:clear_mining_target()
    target.destroy()
  end

  self.mining_count = nil
  self:return_to_depot()



end

function transport_drone:request_order()
  self.depot:handle_order_request(self)
end

local distance = util.distance
function transport_drone:process_return_to_depot()

  local depot = self.depot

  if not (depot and depot.entity.valid) then
    --self:say("My depot isn't valid!")
    self:cancel_command()
    return
  end

  if distance(self.entity.position, depot:get_spawn_position()) > 1 then
    self:return_to_depot()
    return
  end

  if self.stack and (self.stack.count or 0) > 0 and self.stack.name == depot.item then
    depot:get_output_inventory().insert(self.stack)
    self.stack = nil
  end

  self:request_order()

end

function transport_drone:oof()
  local position = self.entity.surface.find_non_colliding_position(self.entity.name, self.entity.position, 0, 0.1, false)
  self.entity.teleport(position)
  --self:say("oof")
end

function transport_drone:process_failed_command()
  --self:oof()
  self.fail_count = (self.fail_count or 0) + 1

  if self.fail_count == 2 then self.entity.ai_settings.path_resolution_modifier = 2 end
  if self.fail_count == 4 then self.entity.ai_settings.path_resolution_modifier = 3 end

  if self.state == states.mining_entity then

    self:clear_attack_proxy()

    if self.mining_target.valid and self.fail_count <= 5 then
      return self:mine_entity(self.mining_target, self.mining_count)
    end

    --self:say("I can't mine that entity!")
    self:clear_mining_target()
    self:return_to_depot()
    return
  end

  if self.state == states.return_to_depot then
    if self.fail_count <= 5 then
      return self:wait(math.random(25, 45))
    end
    --self:say("I can't return to my depot!")
    self:cancel_command()
    return
  end

end

function transport_drone:wait(ticks)
  self.entity.set_command
  {
    type = defines.command.wander,
    ticks_to_wait = ticks,
    distraction = defines.distraction.none
  }
end

function transport_drone:process_pickup()
  local supply_depot = self.supply_depot
  local given_count = supply_depot:give_item(self.requested_name, self.requested_count)

  self.request_depot.on_the_way = self.request_depot.on_the_way - self.requested_count
  self.request_depot.on_the_way = self.request_depot.on_the_way + given_count

  self.held_count = given_count
  self:return_to_requester()
end

function transport_drone:return_to_requester()
  self.state = states.return_to_requester

  self.entity.set_command
  {
    type = defines.command.go_to_location,
    destination_entity = self.request_depot.corpse,
    distraction = defines.distraction.none,
    radius = 0.5,
    pathfind_flags = {prefer_straight_paths = false, use_cache = false}
  }

end

function transport_drone:process_return_to_requester()
  self.request_depot:take_item(self.requested_name, self.held_count)
  remove_drone(self)
  self.entity.destroy()
end

function transport_drone:update(event)
  if not self.entity.valid then return end

  if event.result ~= defines.behavior_result.success then
    self:process_failed_command()
    return
  end

  if self.state == states.going_to_supply then
    self:process_pickup()
    return
  end

  if self.state == states.return_to_requester then
    self:process_return_to_requester()
    return
  end
end

function transport_drone:say(text)
  self.entity.surface.create_entity{name = "flying-text", position = self.entity.position, text = text}
end

function transport_drone:mine_entity(entity, count)
  self.mining_count = count or 1
  self.mining_target = entity
  self.state = states.mining_entity
  local attack_proxy = self:make_attack_proxy(entity, self.mining_count)
  self.attack_proxy = attack_proxy
  local command = {}

  local commands =
  {
    {
      type = defines.command.go_to_location,
      destination_entity = attack_proxy,
      distraction = defines.distraction.none,
      --radius = entity.get_radius() + self.entity.get_radius(),
      pathfind_flags = {prefer_straight_paths = false, use_cache = false}
    },
    {
      type = defines.command.attack,
      target = attack_proxy,
      distraction = defines.distraction.none
    }
  }
  self.entity.set_command
  {
    type = defines.command.compound,
    structure_type = defines.compound_command.return_last,
    commands = commands,
    distraction = defines.distraction.none
  }
end

function transport_drone:clear_things(unit_number)
  self:clear_mining_target()
  self:clear_attack_proxy()
  self:clear_depot(unit_number)
  self:remove_from_list(unit_number)
end

function transport_drone:cancel_command()

  self:clear_things()
  self.entity.force = "neutral"
  self.entity.die()

end

function transport_drone:return_to_depot()
  self.state = states.return_to_depot
  self:clear_attack_proxy()

  local depot = self.depot

  if not (depot and depot.entity.valid) then
    self:cancel_command()
    return
  end

  local corpse = depot.corpse
  if corpse and corpse.valid then
    self:go_to_entity(corpse, 0.75)
    return
  end

  local position = depot:get_spawn_position()
  if position then
    self:go_to_position(position, 0.75)
    return
  end
end

function transport_drone:go_to_position(position, radius)
  self.entity.set_command
  {
    type = defines.command.go_to_location,
    destination = position,
    radius = radius or 1,
    distraction = defines.distraction.none,
    pathfind_flags = {prefer_straight_paths = false, use_cache = false},
  }
end

function transport_drone:go_to_entity(entity, radius)
  self.entity.set_command
  {
    type = defines.command.go_to_location,
    destination_entity = entity,
    radius = radius or 1,
    distraction = defines.distraction.none,
    pathfind_flags = {prefer_straight_paths = false, use_cache = false}
  }
end

function transport_drone:clear_attack_proxy()
  local destroyed = self.attack_proxy and self.attack_proxy.valid and self.attack_proxy.destroy()
  self.attack_proxy = nil
end

function transport_drone:clear_mining_target()
  if self.mining_target and self.mining_target.valid then
    if self.depot then
      self.depot:add_mining_target(self.mining_target)
    end
  end
  self.mining_target = nil
end

function transport_drone:clear_depot(unit_number)
  if not self.depot then return end
  self.depot.drones[unit_number or self.entity.unit_number] = nil
  self.depot = nil
end

function transport_drone:handle_drone_deletion()
  if not self.entity.valid then error("Hi, i am not handled.") end

  if self.depot then
    self.depot:remove_drone(self, true)
  end

  self:clear_things()

end

function transport_drone:is_returning_to_depot()
  return self.state == states.return_to_depot
end

local on_ai_command_completed = function(event)
  local drone = get_drone(tostring(event.unit_number))
  if not drone then return end
  drone:update(event)
end

local on_entity_removed = function(event)
  local entity = event.entity
  if not (entity and entity.valid) then return end

  local unit_number = entity.unit_number
  if not unit_number then return end

  local drone = get_drone(unit_number)
  if not drone then return end

  if event.force and event.force.valid then
    event.force.kill_count_statistics.on_flow(default_bot_name, 1)
  end

  entity.force.kill_count_statistics.on_flow(default_bot_name, -1)

  drone:handle_drone_deletion()

end

function transport_drone:remove_from_list(unit_number)
  if unit_number then
    script_data.drones[unit_number] = nil
  else
    remove_drone(self)
  end
end

local make_unselectable = function()
  if remote.interfaces["unit_control"] then
    for k = 1, shared.variation_count do
      remote.call("unit_control", "register_unit_unselectable", shared.drone_name.."-"..k)
    end
  end
end

local validate_proxy_orders = function()
  --local count = 0
  for unit_number, drone in pairs (script_data.drones) do
    if drone.entity.valid then
      if drone.state == states.mining_entity then
        if not drone.attack_proxy.valid then
          drone:return_to_depot()
          ---count = count + 1
        end
      end
    else
      drone:clear_things(unit_number)
    end
  end
  --game.print(count)
end

local fix_chests = function()
  local used_chests = {}

  for unit_number, drone in pairs (script_data.drones) do
    if drone.inventory and drone.inventory.valid then
      used_chests[drone.inventory.entity_owner.unit_number] = true
    end
  end

  local count = 0
  for k, chest in pairs (game.surfaces[1].find_entities_filtered{name = shared.proxy_chest_name}) do
    if not used_chests[chest.unit_number] then
      chest.destroy()
      count = count + 1
    end
  end
  game.print("Mining drone migration: fixed chest count "..count)
end

local migrate_chests = function()
  game.print("Mining drone removing proxy inventories.")
  for unit_number, drone in pairs (script_data.drones) do
    if drone.inventory and drone.inventory.valid then
      local contents = drone.inventory.get_contents()
      local name, count = next(contents)
      drone.stack = {name = name, count = count}
      drone.inventory.entity_owner.destroy()
      drone.inventory = nil
    end
  end
end



transport_drone.events =
{
  --[defines.events.on_built_entity] = on_built_entity,
  --[defines.events.on_robot_built_entity] = on_built_entity,
  --[defines.events.script_raised_revive] = on_built_entity,
  --[defines.events.script_raised_built] = on_built_entity,

  [defines.events.on_player_mined_entity] = on_entity_removed,
  [defines.events.on_robot_mined_entity] = on_entity_removed,

  [defines.events.on_entity_died] = on_entity_removed,
  [defines.events.script_raised_destroy] = on_entity_removed,

  [defines.events.on_ai_command_completed] = on_ai_command_completed,
}

transport_drone.on_load = function()
  script_data = global.transport_drone or script_data
  for unit_number, drone in pairs (script_data.drones) do
    setmetatable(drone, transport_drone.metatable)
  end
end

transport_drone.on_init = function()
  global.transport_drone = global.transport_drone or script_data
  game.map_settings.path_finder.use_path_cache = false
  make_unselectable()
end

transport_drone.on_configuration_changed = function()
  make_unselectable()
  validate_proxy_orders()
  
  if not script_data.fix_chests then
    script_data.fix_chests = true
    fix_chests()
  end

  if not script_data.migrate_chests then
    script_data.migrate_chests = true
    migrate_chests()
  end
end

transport_drone.get_drone = get_drone

transport_drone.get_drone_count = function()
  return table_size(script_data.drones)
end

return transport_drone
