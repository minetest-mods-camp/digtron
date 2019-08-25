local mod_meta = digtron.mod_meta

local cache = {}

--minetest.debug(dump(mod_meta:to_table()))

-- Wipes mod_meta
--for field, value in pairs(mod_meta:to_table().fields) do
--	mod_meta:set_string(field, "")
--end

local modpath = minetest.get_modpath(minetest.get_current_modname())

local inventory_functions = dofile(modpath.."/inventories.lua")

local retrieve_inventory = inventory_functions.retrieve_inventory
local persist_inventory = inventory_functions.persist_inventory
local get_predictive_inventory = inventory_functions.get_predictive_inventory
local commit_predictive_inventory = inventory_functions.commit_predictive_inventory
local clear_predictive_inventory = inventory_functions.clear_predictive_inventory

digtron.retrieve_inventory = retrieve_inventory -- used by formspecs

--------------------------------------------------------------------------------------

local create_new_id = function()
	local digtron_id = "digtron" .. tostring(math.random(1, 2^21)) -- TODO: use SecureRandom()
	-- It's super unlikely that we'll get a collision, but what the heck - maybe something will go
	-- wrong with the random number source
	while mod_meta:get_string(digtron_id..":layout") ~= "" do
		digtron_id = "digtron" .. tostring(math.random(1, 2^21))
	end	
	return digtron_id
end

-- Deletes a Digtron record. Note: just throws everything away, this is not digtron.disassemble.
local dispose_callbacks = {}
local dispose_id = function(digtron_id)
	-- name doesn't bother caching
	mod_meta:set_string(digtron_id..":name", "")

	-- inventory handles itself specially too
	mod_meta:set_string(digtron_id..":inv", "")
	minetest.remove_detached_inventory(digtron_id)

	-- clears the cache tables
	for i, func in ipairs(dispose_callbacks) do
		func(digtron_id)
	end
end

--------------------------------------------------------------------------------------------
-- Name

-- Not bothering with a dynamic table store for names, they're just strings with no need for serialization or deserialization
digtron.get_name = function(digtron_id)
	return mod_meta:get_string(digtron_id..":name")
end

digtron.set_name = function(digtron_id, digtron_name)
	-- Don't allow a name to be set for a non-existent Digtron
	if mod_meta:get(digtron_id..":layout") then
		mod_meta:set_string(digtron_id..":name", digtron_name)
	end
end

-------------------------------------------------------------------------------------------------------
-- Tables stored to metadata and cached locally

local get_table_functions = function(identifier)
	cache[identifier] = {}
	
	local persist_func = function(digtron_id, tbl)
		mod_meta:set_string(digtron_id..":"..identifier, minetest.serialize(tbl))
		cache[identifier][digtron_id] = tbl
	end
	
	local retrieve_func = function(digtron_id)
		local current = cache[identifier][digtron_id]
		if current then
			return current
		end
		local tbl_string = mod_meta:get_string(digtron_id..":"..identifier)
		if tbl_string ~= "" then
			current = minetest.deserialize(tbl_string)
			if current then
				cache[identifier][digtron_id] = current
			end
			return current
		end
	end
	
	local dispose_func = function(digtron_id)
		mod_meta:set_string(digtron_id..":"..identifier, "")
		cache[identifier][digtron_id] = nil
	end
	
	-- add a callback for dispose_id
	table.insert(dispose_callbacks, dispose_func)
	
	return persist_func, retrieve_func, dispose_func
end

local persist_layout, retrieve_layout = get_table_functions("layout")
local persist_pos, retrieve_pos, dispose_pos = get_table_functions("pos")

digtron.get_pos = retrieve_pos

-------------------------------------------------------------------------------------------------------
-- Layout creation helpers

local cardinal_dirs = {
	{x= 0, y=0,  z= 1},
	{x= 1, y=0,  z= 0},
	{x= 0, y=0,  z=-1},
	{x=-1, y=0,  z= 0},
	{x= 0, y=-1, z= 0},
	{x= 0, y=1,  z= 0},
}
-- Mapping from facedir value to index in cardinal_dirs.
local facedir_to_dir_map = {
	[0]=1, 2, 3, 4,
	5, 2, 6, 4,
	6, 2, 5, 4,
	1, 5, 3, 6,
	1, 6, 3, 5,
	1, 4, 3, 2,
}

-- Turn the cardinal directions into a set of integers you can add to a hash to step in that direction.
local cardinal_dirs_hash = {}
for i, dir in ipairs(cardinal_dirs) do
	cardinal_dirs_hash[i] = minetest.hash_node_position(dir) - minetest.hash_node_position({x=0, y=0, z=0})
end

-- Given a facedir, returns an index into either cardinal_dirs or cardinal_dirs_hash that
-- can be used to determine what this node is "aimed" at
local facedir_to_dir_index = function(param2)
	return facedir_to_dir_map[param2 % 32]
end

-- recursive function searches out all connected unassigned digtron nodes
local get_all_digtron_nodes
get_all_digtron_nodes = function(pos, digtron_nodes, digtron_adjacent, player_name)
	for _, dir in ipairs(cardinal_dirs) do
		local test_pos = vector.add(pos, dir)
		local test_hash = minetest.hash_node_position(test_pos)
		if not (digtron_nodes[test_hash] or digtron_adjacent[test_hash]) then -- don't test twice
			local test_node = minetest.get_node(test_pos)
			local group_value = minetest.get_item_group(test_node.name, "digtron")
			if group_value > 0 then
				local meta = minetest.get_meta(test_pos)
				if meta:contains("digtron_id") then
					-- Node is part of an existing digtron, don't incorporate it
					digtron_adjacent[test_hash] = true
				--elseif TODO test for protected node status using player_name
				else
					--test_node.group_value = group_value -- for later ease of reference
					digtron_nodes[test_hash] = test_node
					get_all_digtron_nodes(test_pos, digtron_nodes, digtron_adjacent, player_name) -- recurse
				end
			else
				-- don't record details, just keeping track of Digtron's borders
				digtron_adjacent[test_hash] = true
			end
		end		
	end
end

-------------------------------------------------------------------------------------------------
-- Cache-only data, not persisted

cache_bounding_box = {}
local update_bounding_box = function(bounding_box, pos)
	bounding_box.minp.x = math.min(bounding_box.minp.x, pos.x)
	bounding_box.minp.y = math.min(bounding_box.minp.y, pos.y)
	bounding_box.minp.z = math.min(bounding_box.minp.z, pos.z)
	bounding_box.maxp.x = math.max(bounding_box.maxp.x, pos.x)
	bounding_box.maxp.y = math.max(bounding_box.maxp.y, pos.y)
	bounding_box.maxp.z = math.max(bounding_box.maxp.z, pos.z)
end
local retrieve_bounding_box = function(digtron_id)
	local val = cache_bounding_box[digtron_id]
	if val then return val end
	
	local layout = retrieve_layout(digtron_id)
	if layout == nil then return nil end

	local bbox = {minp = {x=0, y=0, z=0}, maxp = {x=0, y=0, z=0}}
	for hash, data in pairs(layout) do
		update_bounding_box(bbox, minetest.get_position_from_hash(hash))
	end
	cache_bounding_box[digtron_id] = bbox
	return bbox	
end

cache_all_adjacent_pos = {}
cache_all_digger_targets = {}
local refresh_adjacent = function(digtron_id)
	local layout = retrieve_layout(digtron_id)
	if layout == nil then return nil end
	
	local adjacent = {}
	local adjacent_to_diggers = {}
	for hash, data in pairs(layout) do
		for _, dir_hash in ipairs(cardinal_dirs_hash) do
			local potential_adjacent = hash+dir_hash
			if layout[potential_adjacent] == nil then
				adjacent[potential_adjacent] = true
			end
		end
		
		if minetest.get_item_group(data.node.name, "digtron") == 3 then
			local potential_target = hash + cardinal_dirs_hash[facedir_to_dir_index(data.node.param2)]
			if layout[potential_target] == nil then
				local fields = data.meta.fields
				adjacent_to_diggers[potential_target] = {period = fields.period, offset = fields.offset}
			end
		end		
	end
	cache_all_adjacent_pos[digtron_id] = adjacent
	cache_all_digger_targets[digtron_id] = adjacent_to_diggers
end
local retrieve_all_adjacent_pos = function(digtron_id)
	local val = cache_all_adjacent_pos[digtron_id]
	if val then return val end
	refresh_adjacent(digtron_id)
	return cache_all_adjacent_pos[digtron_id]
end
local retrieve_all_digger_targets = function(digtron_id)
	local val = cache_all_digger_targets[digtron_id]
	if val then return val end
	refresh_adjacent(digtron_id)
	return cache_all_digger_targets[digtron_id]
end

-- call this whenever a stored layout is modified (eg, by rotating it)
-- automatically called on dispose
local invalidate_layout_cache = function(digtron_id)
	cache_bounding_box[digtron_id] = nil
	cache_all_adjacent_pos[digtron_id] = nil
	cache_all_digger_targets[digtron_id] = nil
end
table.insert(dispose_callbacks, invalidate_layout_cache)

--------------------------------------------------------------------------------------------------------
-- assemble and disassemble


-- Returns the id of the new Digtron record, or nil on failure
digtron.assemble = function(root_pos, player_name)
	local node = minetest.get_node(root_pos)
	-- TODO: a more generic test? Not needed with the more generic controller design, as far as I can tell. There's only going to be the one type of controller.
	if node.name ~= "digtron:controller" then 
		-- Called on an incorrect node
		minetest.log("error", "[Digtron] digtron.assemble called with pos " .. minetest.pos_to_string(root_pos)
			.. " but the node at this location was " .. node.name)
		return nil
	end
	local root_meta = minetest.get_meta(root_pos)
	if root_meta:contains("digtron_id") then
		-- Already assembled. TODO: validate that the digtron_id actually exists as well
		minetest.log("error", "[Digtron] digtron.assemble called with pos " .. minetest.pos_to_string(root_pos)
			.. " but the controller at this location was already part of a assembled Digtron.")
		return nil
	end
	local root_hash = minetest.hash_node_position(root_pos)
	local digtron_nodes = {[root_hash] = node} -- Nodes that are part of Digtron.
		-- Initialize with the controller, it won't be added by get_all_adjacent_digtron_nodes
	local digtron_adjacent = {} -- Nodes that are adjacent to Digtron but not a part of it.
	-- There's a slight inefficiency in throwing away digtron_adjacent when retrieve_all_adjacent_pos could
	-- use this info, but it's small and IMO not worth the complexity.
	get_all_digtron_nodes(root_pos, digtron_nodes, digtron_adjacent, player_name)
	
	local digtron_id = create_new_id(root_pos)
	local digtron_inv = retrieve_inventory(digtron_id)
	
	local layout = {}
	
	for hash, node in pairs(digtron_nodes) do
		local relative_hash = hash - root_hash
		local current_meta
		if hash == root_hash then
			current_meta = root_meta -- we're processing the controller, we already have a reference to its meta
		else
			current_meta = minetest.get_meta(minetest.get_position_from_hash(hash))
		end
		
		local current_meta_table = current_meta:to_table()
		
		if current_meta_table.fields.digtron_id then
			-- Trying to incorporate part of an existing digtron, should be impossible.
			minetest.log("error", "[Digtron] digtron.assemble tried to incorporate a Digtron node of type "
				.. node.name .. " at " .. minetest.pos_to_string(minetest.get_position_from_hash(hash))
				.. " that was already assigned to digtron id " .. current_meta_table.fields.digtron_id)
			dispose_id(digtron_id)
			return nil
		end
		-- Process inventories specially
		-- TODO Builder inventory gets turned into an itemname in a special key in the builder's meta
		-- fuel and main get added to corresponding detached inventory lists
		for listname, items in pairs(current_meta_table.inventory) do
			local count = #items
			-- increase the corresponding detached inventory size
			digtron_inv:set_size(listname, digtron_inv:get_size(listname) + count)
			for _, stack in ipairs(items) do
				digtron_inv:add_item(listname, stack)
			end
			-- erase actual items from stored layout metadata, the detached inventory is authoritative
			-- store the inventory size so the inventory can be easily recreated
			current_meta_table.inventory[listname] = #items
		end
		
		local node_def = minetest.registered_nodes[node.name]
		if node_def and node_def._digtron_assembled_node then
			node.name = node_def._digtron_assembled_node
			minetest.swap_node(minetest.get_position_from_hash(hash), node)
		end
			
		node.param1 = nil -- we don't care about param1, wipe it to save space
		layout[relative_hash] = {meta = current_meta_table, node = node}
	end
	
	digtron.set_name(digtron_id, root_meta:get_string("infotext"))
	persist_inventory(digtron_id)
	persist_layout(digtron_id, layout)
	invalidate_layout_cache(digtron_id)
	persist_pos(digtron_id, root_pos)
	
	-- Wipe out the inventories of all in-world nodes, it's stored in the mod_meta now.
	-- Wait until now to do it in case the above loop fails partway through.
	for hash, node in pairs(digtron_nodes) do
		local node_meta
		if hash == root_hash then
			node_meta = root_meta -- we're processing the controller, we already have a reference to its meta
		else
			node_meta = minetest.get_meta(minetest.get_position_from_hash(hash))
		end
		local inv = node_meta:get_inventory()
		
		for listname, items in pairs(inv:get_lists()) do
			for i = 1, #items do
				inv:set_stack(listname, i, ItemStack(""))
			end
		end
		
		node_meta:set_string("digtron_id", digtron_id)
		node_meta:mark_as_private("digtron_id")
	end

	minetest.log("action", "Digtron " .. digtron_id .. " assembled at " .. minetest.pos_to_string(root_pos)
		.. " by " .. player_name)
	minetest.sound_play("digtron_machine_assemble", {gain = 0.5, pos=root_pos})
	
	return digtron_id
end

-- Returns pos, node, and meta for the digtron node provided the in-world node matches the layout
-- returns nil otherwise
local get_valid_data = function(digtron_id, root_hash, hash, data, function_name)
	local node_hash = hash + root_hash -- TODO may want to return this as well?
	local node_pos = minetest.get_position_from_hash(node_hash)
	local node = minetest.get_node(node_pos)
	local node_meta = minetest.get_meta(node_pos)
	local target_digtron_id = node_meta:get_string("digtron_id")

	if data.node.name ~= node.name then
		minetest.log("error", "[Digtron] " .. function_name .. " tried interacting with one of ".. digtron_id .. "'s "
			.. data.node.name .. "s at " .. minetest.pos_to_string(node_pos) .. " but the node at that location was of type "
			.. node.name)
		return
	elseif target_digtron_id ~= digtron_id then
		if target_digtron_id ~= "" then
			minetest.log("error", "[Digtron] " .. function_name .. " tried interacting with ".. digtron_id .. "'s "
				.. data.node.name .. " at " .. minetest.pos_to_string(node_pos)
				.. " but the node at that location had a non-matching digtron_id value of \""
				.. target_digtron_id .. "\"")
			return
		else
			-- Allow digtron to recover from bad map metadata writes, the bane of Digtron 1.0's existence
			minetest.log("warning", "[Digtron] " .. function_name .. " tried interacting with ".. digtron_id .. "'s "
				.. data.node.name .. " at " .. minetest.pos_to_string(node_pos)
				.. " but the node at that location had no digtron_id in its metadata. "
				.. "Since the node type matched the layout, however, it was included anyway. It's possible "
				.. "its metadata was not written correctly by a previous Digtron activity.")
			return node_pos, node, node_meta
		end
	end
	return node_pos, node, node_meta
end

-- Turns the Digtron back into pieces
digtron.disassemble = function(digtron_id, player_name)
	local bbox = retrieve_bounding_box(digtron_id)
	local root_pos = retrieve_pos(digtron_id)
	if not root_pos then
		minetest.log("error", "digtron.disassemble was unable to find a position for " .. digtron_id
			.. ", disassembly was impossible. Has the digtron been removed from world?")
		return
	end

	local root_meta = minetest.get_meta(root_pos)
	root_meta:set_string("infotext", digtron.get_name(digtron_id))
	
	local layout = retrieve_layout(digtron_id)
	local inv = digtron.retrieve_inventory(digtron_id)
	
	if not (layout and inv) then
		minetest.log("error", "digtron.disassemble was unable to find either layout or inventory record for " .. digtron_id
			.. ", disassembly was impossible. Clearing any other remaining data for this id.")
		dispose_id(digtron_id)
		return
	end
	
	local root_hash = minetest.hash_node_position(root_pos)
	
	-- Write metadata and inventory to in-world node at this location
	for hash, data in pairs(layout) do
		local node_pos, node, node_meta = get_valid_data(digtron_id, root_hash, hash, data, "digtron.disassemble")
	
		if node_pos then
			local node_inv = node_meta:get_inventory()
			for listname, size in pairs(data.meta.inventory) do
				node_inv:set_size(listname, size)
				local digtron_inv_list = inv:get_list(listname)
				if digtron_inv_list then
					for i, itemstack in ipairs(digtron_inv_list) do
						-- add everything, putting leftovers back in the main inventory
						inv:set_stack(listname, i, node_inv:add_item(listname, itemstack))
					end
				else
					minetest.log("warning", "[Digtron] inventory list " .. listname .. " existed in " .. node.name
						.. " that was part of " .. digtron_id .. " but was not present in the detached inventory for this digtron."
						.. " This should not have happened, please report an issue to Digtron programmers,"
						.. " but it shouldn't impact digtron disassembly.")
				end
			end
			
			local node_def = minetest.registered_nodes[node.name]
			if node_def and node_def._digtron_disassembled_node then
				minetest.swap_node(node_pos, {name=node_def._digtron_disassembled_node, param2=node.param2})
			end
			
			-- TODO: special handling for builder node inventories

			-- Ensure node metadata fields are all set, too
			for field, value in pairs(data.meta.fields) do
				node_meta:set_string(field, value)
			end
			
			-- Clear digtron_id, this node is no longer part of an active digtron
			node_meta:set_string("digtron_id", "")
		end
	end	

	minetest.log("action", "Digtron " .. digtron_id .. " disassembled at " .. minetest.pos_to_string(root_pos)
		.. " by " .. player_name)
	minetest.sound_play("digtron_machine_disassemble", {gain = 0.5, pos=root_pos})

	dispose_id(digtron_id)

	return root_pos
end

-- Removes the in-world nodes of a digtron
-- Does not destroy its layout info
-- returns a table of vectors of all the nodes that were removed
digtron.remove_from_world = function(digtron_id, player_name)
	local layout = retrieve_layout(digtron_id)
	local root_pos = retrieve_pos(digtron_id)
	
	if not layout then
		minetest.log("error", "digtron.remove_from_world Unable to find layout record for " .. digtron_id
			.. ", wiping any remaining metadata for this id to prevent corruption. Sorry!")
		if root_pos then
			local meta = minetest.get_meta(root_pos)
			meta:set_string("digtron_id", "")
		end
		dispose_id(digtron_id)
		return {}
	end
	
	if not root_pos then
		minetest.log("error", "digtron.remove_from_world Unable to find position for " .. digtron_id
			.. ", it may have already been removed from the world.")
		return {}
	end
	
	local root_hash = minetest.hash_node_position(root_pos)
	local nodes_to_destroy = {}
	for hash, data in pairs(layout) do
		local node_pos = get_valid_data(digtron_id, root_hash, hash, data, "digtron.destroy")
		if node_pos then
			table.insert(nodes_to_destroy, node_pos)
		end
	end
	
	-- TODO: voxelmanip might be better here?
	minetest.bulk_set_node(nodes_to_destroy, {name="air"})
	dispose_pos(digtron_id)
	return nodes_to_destroy
end

-- Tests if a Digtron can be built at the designated location
digtron.is_buildable_to = function(digtron_id, root_pos, player_name, ignore_nodes, return_immediately_on_failure)
	local layout = retrieve_layout(digtron_id)
	
	-- If this digtron is already in-world, we're likely testing as part of a movement attempt.
	-- Record its existing node locations, they will be treated as buildable_to
	local old_pos = retrieve_pos(digtron_id)
	local ignore_hashes = {}
	if old_pos then
		local old_root_hash = minetest.hash_node_position(old_pos)
		for layout_hash, _ in pairs(layout) do
			ignore_hashes[layout_hash + old_root_hash] = true
		end
	end
	if ignore_nodes then
		for _, ignore_pos in ipairs(ignore_nodes) do
			ignore_hashes[minetest.hash_node_position(ignore_pos)] = true
		end
	end
	
	local root_hash = minetest.hash_node_position(root_pos)
	local succeeded = {}
	local failed = {}	
	local permitted = true
	
	for layout_hash, data in pairs(layout) do
		-- Don't use get_valid_data, the Digtron isn't in-world yet
		local node_hash = layout_hash + root_hash
		local node_pos = minetest.get_position_from_hash(node_hash)
		local node = minetest.get_node(node_pos)
		local node_def = minetest.registered_nodes[node.name]
		-- TODO: lots of testing needed here
		if not (
			(node_def and node_def.buildable_to)
			or ignore_hashes[node_hash]) or
			minetest.is_protected(node_pos, player_name)
		then
			if return_immediately_on_failure then
				return false -- no need to test further, don't return node positions
			else
				permitted = false
				table.insert(failed, node_pos)
			end
		elseif not return_immediately_on_failure then
			table.insert(succeeded, node_pos)
		end
	end
	
	return permitted, succeeded, failed
end

-- Places the Digtron into the world.
digtron.build_to_world = function(digtron_id, root_pos, player_name)
	local layout = retrieve_layout(digtron_id)
	local root_hash = minetest.hash_node_position(root_pos)
		
	for hash, data in pairs(layout) do
		-- Don't use get_valid_data, the Digtron isn't in-world yet
		local node_pos = minetest.get_position_from_hash(hash + root_hash)
		minetest.set_node(node_pos, data.node)
		local meta = minetest.get_meta(node_pos)
		for field, value in pairs(data.meta.fields) do
			meta:set_string(field, value)
		end
		meta:set_string("digtron_id", digtron_id)
		meta:mark_as_private("digtron_id")
	end
	persist_pos(digtron_id, root_pos)
	
	return true
end

digtron.move = function(digtron_id, dest_pos, player_name)
	local permitted, succeeded, failed = digtron.is_buildable_to(digtron_id, dest_pos, player_name)
	if permitted then
		local removed = digtron.remove_from_world(digtron_id, player_name)
		digtron.build_to_world(digtron_id, dest_pos, player_name)
		minetest.sound_play("digtron_truck", {gain = 0.5, pos=dest_pos})
		for _, removed_pos in ipairs(removed) do
			minetest.check_for_falling(removed_pos)
		end
	else
		digtron.show_buildable_nodes({}, failed)
		minetest.sound_play("digtron_squeal", {gain = 0.5, pos=dest_pos})
	end	
end

local predict_dig = function(digtron_id, player_name)
	local predictive_inv = get_predictive_inventory(digtron_id)
	local layout = retrieve_layout(digtron_id)
	local root_pos = retrieve_pos(digtron_id)
	if not (layout and root_pos and predictive_inv) then
		minetest.log("error", "[Digtron] predict_dig failed to retrieve either "
			.."a predictive inventory, a layout, or a root position for " .. digtron_id)
		return
	end
	local root_hash = minetest.hash_node_position(root_pos)
	
	local leftovers = {}
	local dug_positions = {}
	local cost = 0
	
	for target_hash, digger_data in pairs(retrieve_all_digger_targets(digtron_id)) do
		local target_pos = minetest.get_position_from_hash(target_hash + root_hash)
		local target_node = minetest.get_node(target_pos)
		local target_name = target_node.name
		local targetdef = minetest.registered_nodes[target_name]
		--TODO periodicity/offset test
		if
			target_name ~= "air" and -- TODO: generalise this somehow for liquids and other undiggables
			minetest.get_item_group(target_name, "digtron") == 0 and
			minetest.get_item_group(target_name, "digtron_protected") == 0 and
			minetest.get_item_group(target_name, "immortal") == 0 and
			(
				targetdef == nil or -- can dig undefined nodes, why not
				targetdef.can_dig == nil or
				targetdef.can_dig(target_pos, minetest.get_player_by_name(player_name))
			) and
			not minetest.is_protected(target_pos, player_name)
		then
			local material_cost = 0
			if digtron.config.uses_resources then
				local in_known_group = false
				if minetest.get_item_group(target_name, "cracky") ~= 0 then
					in_known_group = true
					material_cost = math.max(material_cost, digtron.config.dig_cost_cracky)
				end
				if minetest.get_item_group(target_name, "crumbly") ~= 0 then
					in_known_group = true
					material_cost = math.max(material_cost, digtron.config.dig_cost_crumbly)
				end
				if minetest.get_item_group(target_name, "choppy") ~= 0 then
					in_known_group = true
					material_cost = math.max(material_cost, digtron.config.dig_cost_choppy)
				end
				if not in_known_group then
					material_cost = digtron.config.dig_cost_default
				end
			end
			cost = cost + material_cost
	
			local drops = minetest.get_node_drops(target_name, "")
			for _, drop in ipairs(drops) do
				local leftover = predictive_inv:add_item("main", ItemStack(drop))
				if leftover:get_count() > 0 then
					table.insert(leftovers, leftover)
				end
			end
			table.insert(dug_positions, target_pos)
		end
	end

	return leftovers, dug_positions, cost
end

-- Removes nodes and records node info so execute_dug_callbacks can be called later
local get_and_remove_nodes = function(nodes_to_dig)
	local ret = {}
	for _, pos in ipairs(nodes_to_dig) do
		local record = {}
		record.pos = pos
		record.node = minetest.get_node(pos)
		record.meta = minetest.get_meta(pos)
		minetest.remove_node(pos)
		table.insert(ret, record)
	end
	return ret
end

local log_dug_nodes = function(nodes_to_dig, digtron_id, root_pos, player_name)
	local nodes_dug_count = #nodes_to_dig
	if nodes_dug_count > 0 then
		local pluralized = "node"
		if nodes_dug_count > 1 then
			pluralized = "nodes"
		end
		minetest.log("action", nodes_dug_count .. " " .. pluralized .. " dug by "
			.. digtron_id .. " near ".. minetest.pos_to_string(root_pos)
			.. " operated by by " .. player_name)
	end
end

local execute_dug_callbacks = function(nodes_dug)
	-- Execute various on-dig callbacks for the nodes that Digtron dug
	for _, dug_data in ipairs(nodes_dug) do
		local old_pos = dug_data.pos
		local old_node = dug_data.node
		local old_name = old_node.name

		for _, callback in ipairs(minetest.registered_on_dignodes) do
			-- Copy pos and node because callback can modify them
			local pos_copy = {x=old_pos.x, y=old_pos.y, z=old_pos.z}
			local oldnode_copy = {name=old_name, param1=old_node.param1, param2=old_node.param2}
			callback(pos_copy, oldnode_copy, digtron.fake_player)
		end

		local old_def = minetest.registered_nodes[old_name]
		if old_def ~= nil then
			local old_after_dig = old_def.after_dig_node
			if old_after_dig ~= nil then
				old_after_dig(old_pos, old_node, dug_data.meta, digtron.fake_player)
			end
		end
	end
end

digtron.execute_cycle = function(digtron_id, player_name)
	local leftovers, nodes_to_dig, cost = predict_dig(digtron_id, player_name)
	local old_root_pos = retrieve_pos(digtron_id)
	local root_node = minetest.get_node(old_root_pos)
	local new_root_pos = vector.add(old_root_pos, cardinal_dirs[facedir_to_dir_index(root_node.param2)])
	local buildable_to, succeeded, failed = digtron.is_buildable_to(digtron_id, new_root_pos, player_name, nodes_to_dig)

	if buildable_to then
		digtron.fake_player:update(old_root_pos, player_name)
		
		-- Removing old nodes
		local removed = digtron.remove_from_world(digtron_id, player_name)
		local nodes_dug = get_and_remove_nodes(nodes_to_dig, player_name)
		log_dug_nodes(nodes_to_dig, digtron_id, old_root_pos, player_name)
		
		-- Building new Digtron
		digtron.build_to_world(digtron_id, new_root_pos, player_name)
		minetest.sound_play("digtron_construction", {gain = 0.5, pos=new_root_pos})
		
		-- TODO add build portion of the cycle
		
		-- Don't need to do fancy callback checking for digtron nodes since I made all those
		-- nodes and I know they don't have anything that needs to be done for them.
		-- Just check for falling nodes.
		for _, removed_pos in ipairs(removed) do
			minetest.check_for_falling(removed_pos)
		end

		-- Must be called after digtron.build_to_world because it triggers falling nodes
		execute_dug_callbacks(nodes_dug)
	
		commit_predictive_inventory(digtron_id)
	else
		clear_predictive_inventory(digtron_id)
		digtron.show_buildable_nodes({}, failed)
		minetest.sound_play("digtron_squeal", {gain = 0.5, pos=new_pos})
	end
end


---------------------------------------------------------------------------------
-- Node callbacks

-- If the digtron node has an assigned ID and a layout for that ID exists and
-- a matching node exists in the layout then don't let it be dug.
-- TODO: add protection check?
digtron.can_dig = function(pos, digger)
	local meta = minetest.get_meta(pos)
	local digtron_id = meta:get_string("digtron_id")
	if digtron_id == "" then
		return true
	end

	local node = minetest.get_node(pos)
	
	local root_pos = retrieve_pos(digtron_id)
	local layout = retrieve_layout(digtron_id)
	if root_pos == nil or layout == nil then
		-- Somehow, this belongs to a digtron id that's missing information that should exist in persistence.
		local missing = ""
		if root_pos == nil then missing = missing .. "root_pos " end
		if layout == nil then missing = missing .. "layout " end
		
		minetest.log("error", "[Digtron] can_dig was called on a " .. node.name .. " at location "
			.. minetest.pos_to_string(pos) .. " that claimed to belong to " .. digtron_id
			.. ". However, layout and/or location data are missing: " .. missing)
		-- May be better to do this to prevent node duplication. But we're already in bug land here so tread gently.
		--minetest.remove_node(pos)
		--return false
		return true
	end
	
	local root_hash = minetest.hash_node_position(root_pos)
	local here_hash = minetest.hash_node_position(pos)
	local layout_hash = here_hash - root_hash
	local layout_data = layout[layout_hash]
	if layout_data == nil or layout_data.node == nil then
		minetest.log("error", "[Digtron] can_dig was called on a " .. node.name .. " at location "
			.. minetest.pos_to_string(pos) .. " that claimed to belong to " .. digtron_id
			.. ". However, the layout for that digtron_id didn't contain any corresponding node at its location.")
		return true
	end
	if layout_data.node.name ~= node.name or layout_data.node.param2 ~= node.param2 then
		minetest.log("error", "[Digtron] can_dig was called on a " .. node.name .. " with param2 "
			.. node.param2 .." at location " .. minetest.pos_to_string(pos) .. " that belonged to " .. digtron_id
			.. ". However, the layout for that digtron_id contained a " .. layout_data.node.name
			.. "with param2 ".. layout_data.node.param2 .. " at its location.")
		return true
	end
	
	-- We're part of a valid Digtron. No touchy.
	return false
end

-- put this on all Digtron nodes. If other inventory types are added (eg, batteries)
-- update this.
digtron.on_blast = function(pos, intensity)
	if intensity < 1.0 then return end -- The Almighty Digtron ignores weak-ass explosions

	local meta = minetest.get_meta(pos)
	local digtron_id = meta:get_string("digtron_id")
	if digtron_id ~= "" then
		if not digtron.disassemble(digtron_id, "an explosion") then
			minetest.log("error", "[Digtron] a digtron node at " .. minetest.pos_to_string(pos)
				.. " was hit by an explosion and had digtron_id " .. digtron_id
				.. " but didn't have a root position recorded, so it could not be disassembled.")
			return
		end
	end

	local drops = {}
	default.get_inventory_drops(pos, "main", drops)
	default.get_inventory_drops(pos, "fuel", drops)
	local node = minetest.get_node(pos)
	table.insert(drops, ItemStack(node.name))	
	minetest.remove_node(pos)
	return drops
end


------------------------------------------------------------------------------------
-- Creative trash

-- Catch when someone throws a Digtron controller with an ID into the trash, dispose
-- of the persisted layout.
if minetest.get_modpath("creative") then
	local trash = minetest.detached_inventories["creative_trash"]
	if trash then
		local old_on_put = trash.on_put
		if old_on_put then
			local digtron_on_put = function(inv, listname, index, stack, player)
				local stack = inv:get_stack(listname, index)
				local stack_meta = stack:get_meta()
				local digtron_id = stack_meta:get_string("digtron_id")
				if stack:get_name() == "digtron:controller" and digtron_id ~= "" then
					minetest.log("action", player:get_player_name() .. " disposed of " .. digtron_id
						.. " in the creative inventory's trash receptacle.")
					dispose_id(digtron_id)
				end
				return old_on_put(inv, listname, index, stack, player)
			end
		trash.on_put = digtron_on_put
		end
	end
end
