-- internationalization boilerplate
local MP = minetest.get_modpath(minetest.get_current_modname())
local S, NS = dofile(MP.."/intllib.lua")

local listname_to_title =
{
	["main"] = S("Main Inventory"),
	["fuel"] = S("Fuel"),
}

-- Sequencer commands
-- Yes, this indexing scheme is complicated. It's necessary in order to make sequences
-- language-agnostic, and saves a bit of storage space in the process by shortening and 
-- standardizing command tags.
-- Also makes it future-proof, we can add new commands without disrupting existing stored sequences
local sequencer_commands = 
{
	seq = S("Sequence"),
	dmb = S("Dig Move Build"),
	dmd = S("Dig Move Down"),
	mup = S("Move Up"),
	mdn = S("Move Down"),
	mlt = S("Move Left"),
	mrt = S("Move Right"),
	mfw = S("Move Forward"),
	mbk = S("Move Back"),
	rlt = S("Yaw Left"),
	rrt = S("Yaw Right"),
	rup = S("Pitch Up"),
	rdn = S("Pitch Down"),
	rcl = S("Roll Clockwise"),
	rcc = S("Roll Widdershins"),
}

-- This sets the order in which they'll be shown on the dropdown menu
local sequencer_dropdown_order = 
{
	"seq", "dmb", "dmd", "mup", "mdn", "mlt", "mrt", "mfw", "mbk", "rlt", "rrt", "rup", "rdn", "rcl", "rcc"
}
-- Allows commands to be turned into an index into the dropdown order, needed for defaulting to the current command when building the formspec
local sequencer_dropdown_order_reverse = {}
for i, command in ipairs(sequencer_dropdown_order) do
	sequencer_dropdown_order_reverse[command] = i
end

-- Build the actual text string used in the formspec dropdown
local sequencer_dropdown_list = {}
for _, cmd in ipairs(sequencer_dropdown_order) do
	table.insert(sequencer_dropdown_list, sequencer_commands[cmd])
end
sequencer_dropdown_list = table.concat(sequencer_dropdown_list, ",")

-- Reverse lookup from human-readable command to internal tag, used in on_recieve_fields processing
local sequencer_commands_reverse = {}
for cmd, command in pairs(sequencer_commands) do
	sequencer_commands_reverse[command] = cmd
end


-- Manipulating sequences

-- Recursively builds a formspec representation. Dropdowns and buttons are indexed with : delimiters, eg:
--:1
--:2
--:2:1
--:2:2
--:2:2:1
--:3
local create_sequence_list
create_sequence_list = function(sequence_in, list_out, root_index, x, y)
	root_index = root_index or ""
	x = x or 0
	y = y or 0
	
	for i, val in ipairs(sequence_in) do
		local index = root_index .. ":" .. i
		local line = "dropdown[".. x ..","..y..";1.5;sequencer_com"..index..";"..sequencer_dropdown_list..";"
			..sequencer_dropdown_order_reverse[val.cmd].."]field["
			.. x+1.75 ..",".. y+0.25 ..";1,1;sequencer_cnt"..index..";;"..val.cnt.."]"..
			"field_close_on_enter[sequencer_cnt_"..i..";false]"..
			"button[".. x+ 2.375 .. ","..y-0.0625 ..";1,1;sequencer_del"..index..";"..S("Delete").."]"
		if val.cmd == "seq" then
			line = line .. "button[".. x+3.25 ..","..y-0.0625 ..";1,1;sequencer_ins"..index..";"..S("Insert").."]"
			table.insert(list_out, line)
			y = y + 0.8
			-- Recurse into sub-sequence
			y = create_sequence_list(val.seq, list_out, index, x+0.5, y)
		else
			table.insert(list_out, line)
			y = y + 0.8
		end
	end

	return y
end

-- all field prefixes in the above create_sequence_list should be of this length
local sequencer_field_length = string.len("sequencer_com:")

local find_item = function(field, sequence)
	local index_list = field:sub(sequencer_field_length+1):split(":")
	local target = {seq = sequence}
	for i = 1, #index_list do
		target = target.seq[tonumber(index_list[i])]
		if target == nil then
			minetest.log("error", "[Digtron] find_item failed to find a sequence item.")
			return nil
		end
	end
	return target
end

local delete_item = function(field, sequence)
	local index_list = field:sub(sequencer_field_length+1):split(":")
	local target = {seq = sequence}
	for i = 1, #index_list-1 do
		target = target.seq[tonumber(index_list[i])]
		if target == nil then
			minetest.log("error", "[Digtron] delete_item failed to find a sequence item.")
			return nil
		end
	end	
	table.remove(target.seq, tonumber(index_list[#index_list]))
end

-- recurses through sequences ensuring there are tables for seq commands
local clean_subsequences
clean_subsequences = function(sequence)
	for i, val in ipairs(sequence) do
		if val.cmd == "seq" then
			if val.seq == nil then
				val.seq = {}
			else
				clean_subsequences(val.seq)
			end
		else
			val.seq = nil
		end
	end
end

local update_sequence = function(digtron_id, fields)
	local sequence = digtron.get_sequence(digtron_id)
	local delete_field = nil
	local insert_field = nil
	for field, value in pairs(fields) do
		local command_type = field:sub(1,sequencer_field_length)
		if command_type == "sequencer_com:" then
			local seq_item = find_item(field, sequence)
			seq_item.cmd = sequencer_commands_reverse[value]
		elseif command_type == "sequencer_cnt:" then
			local val_int = tonumber(value)
			if val_int then
				val_int = math.floor(val_int)
				local seq_item = find_item(field, sequence)
				seq_item.cnt = val_int
			end
				
		--Save these to do last so as to not invalidate indices
		--Adding and removing items makes find_item not work
		elseif command_type == "sequencer_del:" then
			delete_field = field
		elseif command_type == "sequencer_ins:" then
			insert_field = field
		end
	end
	
	if insert_field and delete_field then
		minetest.log("error", "[Digtron] somehow an insertion and a deletion were both registered for a single update_sequence call. "
			.. "ignoring the deletion.")
		delete_field = nil
	end
	
	if insert_field then
		local item = find_item(insert_field, sequence)
		table.insert(item.seq, {cmd="dmb",cnt=1})
	elseif delete_field then
		delete_item(delete_field, sequence)
	end
	
	if fields.sequencer_insert_end then
		table.insert(sequence, {cmd="dmb",cnt=1})
	end
	
	clean_subsequences(sequence) -- if commands were changed to or away from "seq", ensure they have a .seq member
	digtron.set_sequence(digtron_id, sequence)
end

-- This allows us to know which digtron the player has a formspec open for without
-- sending the digtron_id over the network
local player_interacting_with_digtron_id = {}

local get_controller_assembled_formspec = function(digtron_id, player_name)
	local context = player_interacting_with_digtron_id[player_name]
	if context == nil or context.digtron_id ~= digtron_id then
		minetest.log("error", "[Digtron] get_controller_assembled_formspec was called for Digtron "
			..digtron_id .. " by " .. player_name .. " but there was no context recorded or the context was"
			.." for the wrong digtron. This shouldn't be possible.")
		return ""
	end
	
	local inv = digtron.get_inventory(digtron_id) -- ensures the detatched inventory exists and is populated
	
	-- TODO: will probably want a centralized cache for most of this, right now there's tons of redundancy
	if context.tabs == nil then
		context.tabs = {}
		local lists = inv:get_lists()
		for listname, contents in pairs(lists) do
			table.insert(context.tabs, {
				tab_type = "inventory",
				listname = listname,
				size = #contents,
				pages = math.floor(#contents/(8*4)) + 1,
				current_page = 1})
		end
		context.current_tab = 1
	end

	local position_and_anchor = "position[0.025,0.1]anchor[0,0]"

	local tabs = "tabheader[0,0;tab_header;"..S("Controls")..","..S("Sequence")
	for _, tab in ipairs(context.tabs) do
		tabs = tabs .. "," .. listname_to_title[tab.listname] or tab.listname
	end
	tabs = tabs .. ";" .. context.current_tab .. "]"
	
	local inv_tab = function(inv_tab_context)
		local inv_list = inv_tab_context.listname
		local pages = inv_tab_context.pages
		local current_page = inv_tab_context.current_page
		local starting_index = (current_page - 1) * 8 * 4
		local paging_controls = ""
		if pages > 1 then
			paging_controls = "button[0,0;1,1;page_back;<<]"
			.. "label[1.125,0.25;"..S("Page @1/@2", current_page, pages) .. "]"
			.. "button[2,0;1,1;page_forward;>>]"
		end
		
		return "size[8,9]"
			.. position_and_anchor
			.. "container[0,0]"
			.. "list[detached:" .. digtron_id .. ";"..inv_list..";0,0;8,4;"..starting_index.."]"
			.. "container_end[]"
			.. "container[2.5,4]" .. paging_controls .. "container_end[]"
			.. "container[0,5]list[current_player;main;0,0;8,1;]list[current_player;main;0,1.25;8,3;8]container_end[]"
			.. "listring[current_player;main]"
			.. "listring[detached:" .. digtron_id .. ";"..inv_list.."]"
	end
	
	local sequence_tab = function()
		local sequence = digtron.get_sequence(digtron_id)
		local list_out = {}
		local y = create_sequence_list(sequence, list_out)
		return "size[4.2,5]"
			.. position_and_anchor
			.. "container[0,0]"
			.. table.concat(list_out)
			.. "button[0,"..y-0.0625 ..";1,1;sequencer_insert_end;"..S("New\nCommand").."]"
			.. "container_end[]"
	end
	
	local controls = "size[4.2,5]"
		.. position_and_anchor
		.. "container[0,0]"
		.. "button[0,0;1,1;disassemble;"..S("Disassemble").."]"
		.. "field[1.2,0.3;1.75,1;digtron_name;"..S("Digtron name")..";"
		.. minetest.formspec_escape(digtron.get_name(digtron_id)).."]"
		.. "field_close_on_enter[digtron_name;false]"
		.. "field[2.9,0.3;0.7,1;cycles;"..S("Cycles")..";1]" -- TODO persist, actually use
		.. "button[3.2,0;1,1;execute;"..S("Execute").."]"
		.. "button[3.7,0;1,1;execute_down;Dig Down]" -- TODO: for testing purposes only, remove once sequences actually work
		.. "container_end[]"
		
		.. "container[0,1]"
		.. "box[0,0;4,2;#DDDDDD]"
		.. "label[1.8,0.825;"..S("Move").."]"
		.. "button[1.1,0.1;1,1;move_up;"..S("Up").."]"
		.. "button[1.1,1.1;1,1;move_down;"..S("Down").."]"
		.. "button[2.1,0.1;1,1;move_forward;"..S("Forward").."]"
		.. "button[2.1,1.1;1,1;move_back;"..S("Back").."]"
		.. "button[0.1,0.6;1,1;move_left;"..S("Left").."]"
		.. "button[3.1,0.6;1,1;move_right;"..S("Right").."]"
		.. "container_end[]"

		.. "container[0.5,3.2]"
		.. "box[0,0;3,2;#DDDDDD]"
		.. "label[1.3,0.825;"..S("Rotate").."]"
		.. "button[0.1,0.1;1,1;rot_counterclockwise;"..S("Roll\nWiddershins").."]"
		.. "button[2.1,0.1;1,1;rot_clockwise;"..S("Roll\nClockwise").."]"
		.. "button[1.1,0.1;1,1;rot_up;"..S("Pitch Up").."]"
		.. "button[1.1,1.1;1,1;rot_down;"..S("Pitch Down").."]"
		.. "button[0.1,1.1;1,1;rot_left;"..S("Yaw Left").."]"
		.. "button[2.1,1.1;1,1;rot_right;"..S("Yaw Right").."]"
		.. "container_end[]"
		
	if context.current_tab == 1 then
		return controls .. tabs
	elseif context.current_tab == 2 then
		return sequence_tab() .. tabs
	else
		local inv_tab_context = context.tabs[context.current_tab - 2]
		return inv_tab(inv_tab_context) .. tabs
	end
end

-- Controlling a fully armed and operational Digtron
minetest.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= "digtron:controller_assembled" then
		return
	end
	local player_name = player:get_player_name()
	
	-- Get and validate various values
	local context = player_interacting_with_digtron_id[player_name]
	if context == nil then
		minetest.log("error", "[Digtron] player_interacting_with_digtron_id context not found for " .. player_name)
		return
	end
	local digtron_id = context.digtron_id
	if digtron_id == nil then
		minetest.log("error", "[Digtron] player_interacting_with_digtron_id context had no digtron id for " .. player_name)
		return
	end
	local pos = digtron.get_pos(digtron_id)
	if pos == nil then
		minetest.log("error", "[Digtron] controller was unable to look up a position for digtron id for " .. digtron_id)
		return
	end
	local node = minetest.get_node(pos)
	if node.name ~= "digtron:controller" then
		minetest.log("error", "[Digtron] player " .. player_name .. " interacted with the controller for "
			.. digtron_id .. " but the node at " .. minetest.pos_to_string(pos) .. " was a " ..node.name
			.. " rather than a digtron:controller")
		return
	end

	local current_tab = context.current_tab
	local refresh = false
	if fields.tab_header then
		local new_tab = tonumber(fields.tab_header)
		if new_tab <= #(context.tabs) + 2 then
			context.current_tab = new_tab
			refresh = true
		else
			minetest.log("error", "[Digtron] digtron:controller_assembled formspec returned the out-of-range tab index "
				.. new_tab)
		end
	end

	if current_tab == 1 then
		-- Controls
		if fields.disassemble then
			local pos = digtron.disassemble(digtron_id, player_name)
			minetest.close_formspec(player_name, formname)
		end
		
		local facedir = node.param2
		-- Translation
		if fields.move_forward then
			digtron.move(digtron_id, vector.add(pos, digtron.facedir_to_dir(facedir)), player_name)
		elseif fields.move_back then
			digtron.move(digtron_id, vector.add(pos, vector.multiply(digtron.facedir_to_dir(facedir), -1)), player_name)
		elseif fields.move_up then
			digtron.move(digtron_id, vector.add(pos, digtron.facedir_to_up(facedir)), player_name)
		elseif fields.move_down then
			digtron.move(digtron_id, vector.add(pos, vector.multiply(digtron.facedir_to_up(facedir), -1)), player_name)
		elseif fields.move_left then
			digtron.move(digtron_id, vector.add(pos, vector.multiply(digtron.facedir_to_right(facedir), -1)), player_name)
		elseif fields.move_right then
			digtron.move(digtron_id, vector.add(pos, digtron.facedir_to_right(facedir)), player_name)
		-- Rotation	
		elseif fields.rot_counterclockwise then
			digtron.rotate(digtron_id, vector.multiply(digtron.facedir_to_dir(facedir), -1), player_name)
		elseif fields.rot_clockwise then
			digtron.rotate(digtron_id, digtron.facedir_to_dir(facedir), player_name)
		elseif fields.rot_up then
			digtron.rotate(digtron_id, digtron.facedir_to_right(facedir), player_name)
		elseif fields.rot_down then
			digtron.rotate(digtron_id, vector.multiply(digtron.facedir_to_right(facedir), -1), player_name)
		elseif fields.rot_left then
			digtron.rotate(digtron_id, vector.multiply(digtron.facedir_to_up(facedir), -1), player_name)
		elseif fields.rot_right then
			digtron.rotate(digtron_id, digtron.facedir_to_up(facedir), player_name)
		end
	
		if fields.execute then
			digtron.execute_dig_move_build_cycle(digtron_id, player_name)
		end
		
		if fields.execute_down then
			digtron.execute_dig_move_build_cycle(digtron_id, player_name, true)
		end
		
		if fields.key_enter_field == "digtron_name" or fields.digtron_name then
			local pos = digtron.get_pos(digtron_id)
			if pos then
				local meta = minetest.get_meta(pos)
				meta:set_string("infotext", fields.digtron_name)
				digtron.set_name(digtron_id, fields.digtron_name)
			end
		end
		
	elseif current_tab == 2 then
		--Sequencer
		update_sequence(digtron_id, fields)
		refresh = true
	else -- inventory tabs
		local tab_context = context.tabs[current_tab - 2]
		if fields.page_forward then
			if tab_context.current_page < tab_context.pages then
				tab_context.current_page = tab_context.current_page + 1
				refresh = true
			end
		end
		if fields.page_back then
			if tab_context.current_page > 1 then
				tab_context.current_page = tab_context.current_page - 1
				refresh = true
			end		
		end	
	end
	
	if refresh then
		minetest.show_formspec(player_name,
			"digtron:controller_assembled",
			get_controller_assembled_formspec(digtron_id, player_name))
	end	
end)

-- Doesn't deep-copy
local combine_defs = function(base_def, override_content)
	local out = {}
	for key, value in pairs(base_def) do
		out[key] = value
	end
	for key, value in pairs(override_content) do
		out[key] = value
	end
	return out
end

local base_def = {
	_doc_items_longdesc = nil,
    _doc_items_usagehelp = nil,
	-- Note: this is not in the "digtron" group because we do not want it to be incorporated
	-- into digtrons by mere adjacency; it must be the root node and only one root node is allowed.
	groups = {cracky = 3, oddly_breakable_by_hand = 3},
	paramtype = "light",
	paramtype2= "facedir",
	is_ground_content = false,
	drawtype = "nodebox",
		node_box = {
		type = "fixed",
		fixed = {
			{-0.3125, -0.3125, -0.3125, 0.3125, 0.3125, 0.3125}, -- Core
			{-0.1875, 0.3125, -0.1875, 0.1875, 0.5, 0.1875}, -- +y_connector
			{-0.1875, -0.5, -0.1875, 0.1875, -0.3125, 0.1875}, -- -y_Connector
			{0.3125, -0.1875, -0.1875, 0.5, 0.1875, 0.1875}, -- +x_connector
			{-0.5, -0.1875, -0.1875, -0.3125, 0.1875, 0.1875}, -- -x_connector
			{-0.1875, -0.1875, 0.3125, 0.1875, 0.1875, 0.5}, -- +z_connector
			{-0.5, 0.125, -0.5, -0.125, 0.5, -0.3125}, -- back_connector_3
			{0.125, 0.125, -0.5, 0.5, 0.5, -0.3125}, -- back_connector_1
			{0.125, -0.5, -0.5, 0.5, -0.125, -0.3125}, -- back_connector_2
			{-0.5, -0.5, -0.5, -0.125, -0.125, -0.3125}, -- back_connector_4
		},
	},
	sounds = default.node_sound_metal_defaults(),
	on_blast = digtron.on_blast,
}

minetest.register_node("digtron:controller_unassembled", combine_defs(base_def, {
	description = S("Digtron Control Module"),
	_digtron_assembled_node = "digtron:controller",
	tiles = {
		"digtron_plate.png^[transformR90",
		"digtron_plate.png^[transformR270",
		"digtron_plate.png",
		"digtron_plate.png^[transformR180",
		"digtron_plate.png",
		"digtron_plate.png^digtron_control.png",
	},

	on_rightclick = function(pos, node, clicker, itemstack, pointed_thing)
		local returnstack, success = digtron.on_rightclick(pos, node, clicker, itemstack, pointed_thing)
		if returnstack then
			return returnstack, success
		end

		if clicker == nil then return end
		
		local player_name = clicker:get_player_name()
		local digtron_id = digtron.assemble(pos, player_name)
		if digtron_id then
			local meta = minetest.get_meta(pos)
			meta:set_string("digtron_id", digtron_id)
			meta:mark_as_private("digtron_id")
			player_interacting_with_digtron_id[player_name] = {digtron_id = digtron_id}
			minetest.show_formspec(player_name,
				"digtron:controller_assembled",
				get_controller_assembled_formspec(digtron_id, player_name))
		end
	end
}))

minetest.register_node("digtron:controller", combine_defs(base_def, {
	description = S("Digtron Assembly"), -- Will normally be obscured by the player-set Digtron name
	tiles = {
		"digtron_plate.png^[transformR90",
		"digtron_plate.png^[transformR270",
		"digtron_plate.png",
		"digtron_plate.png^[transformR180",
		"digtron_plate.png",
		"digtron_plate.png^digtron_control.png^digtron_intermittent.png",
	},
	_digtron_disassembled_node = "digtron:controller_unassembled",
	groups = {cracky = 3, oddly_breakable_by_hand = 3, not_in_creative_inventory = 1},
	
	on_dig = function(pos, node, digger)
		local player_name
		if digger then
			player_name = digger:get_player_name()
		end
		local meta = minetest.get_meta(pos)
		local digtron_id = meta:get_string("digtron_id")
		
		local stack = ItemStack({name=node.name, count=1, wear=0})
		local stack_meta = stack:get_meta()
		stack_meta:set_string("digtron_id", digtron_id)
		stack_meta:set_string("description", meta:get_string("infotext"))
		local inv = digger:get_inventory()
		local stack = inv:add_item("main", stack)
		if stack:get_count() > 0 then
			minetest.add_item(pos, stack)
		end		
		-- TODO call on_dignodes callback
		if digtron_id ~= "" then
			local removed = digtron.remove_from_world(digtron_id, player_name)
			if removed then
				for _, removed_pos in ipairs(removed) do
					minetest.check_for_falling(removed_pos)
				end
			else
				minetest.remove_node(pos)
			end
		else
			minetest.remove_node(pos)
		end
	end,
	
	preserve_metadata = function(pos, oldnode, oldmeta, drops)
		for _, dropped in ipairs(drops) do
			if dropped:get_name() == "digtron:controller" then
				local stack_meta = dropped:get_meta()
				stack_meta:set_string("digtron_id", oldmeta:get_string("digtron_id"))
				stack_meta:set_string("description", oldmeta:get_string("infotext"))
				return
			end
		end
	end,
	
	on_place = function(itemstack, placer, pointed_thing)
        -- Shall place item and return the leftover itemstack.
        -- The placer may be any ObjectRef or nil.
		local player_name
		if placer then player_name = placer:get_player_name() end
		
		local stack_meta = itemstack:get_meta()
		local digtron_id = stack_meta:get_string("digtron_id")
		if digtron_id ~= "" then
			local target_pos
			local below_node = minetest.get_node(pointed_thing.under)
			local below_def = minetest.registered_nodes[below_node.name]
			if below_def.buildable_to then
				target_pos = pointed_thing.under
			else
				target_pos = pointed_thing.above
			end
			-- TODO rotate layout based on player orientation
			
			-- move up so that the lowest y-coordinate on the Digtron is
			-- at the y-coordinate of the place clicked on and test again.
			local bbox = digtron.get_bounding_box(digtron_id)
			if bbox then			
				target_pos.y = target_pos.y + math.abs(bbox.minp.y)
	
				if target_pos then
					local success, succeeded, failed = digtron.is_buildable_to(digtron_id, nil, target_pos, player_name)
					if success then
						local built_positions = digtron.build_to_world(digtron_id, nil, target_pos, player_name)
						for _, built_pos in ipairs(built_positions) do
							minetest.check_for_falling(built_pos)
						end
	
						minetest.sound_play("digtron_machine_assemble", {gain = 0.5, pos=target_pos})
						-- Note: DO NOT RESPECT CREATIVE MODE here.
						-- If we allow multiple copies of a Digtron running around with the same digtron_id,
						-- human sacrifice, dogs and cats living together, mass hysteria
						return ItemStack("")
					else
						-- if that fails, show ghost of Digtron and fail to place.
						digtron.show_buildable_nodes(succeeded, failed)
						minetest.sound_play("digtron_buzzer", {gain = 0.5, pos=target_pos})
					end
				end
			else
				minetest.log("error", "[Digtron] digtron:controller on_place failed to find data for " .. digtron_id
					.. ", placing an unassembled controller.")
				itemstack:set_name("digtron:controller_unassembled")
				return minetest.item_place(itemstack, placer, pointed_thing)
			end
			return itemstack
		else
			-- Should be impossible to have a controller without an ID, but if it happens place an unassembled node
			itemstack:set_name("digtron:controller_unassembled")
			return minetest.item_place(itemstack, placer, pointed_thing)
		end
	end,
	
	after_place_node = function(pos, placer, itemstack, pointed_thing)
		local stack_meta = itemstack:get_meta()
		local title = stack_meta:get_string("description")
		local digtron_id = stack_meta:get_string("digtron_id")
		
		local meta = minetest.get_meta(pos)
			
		meta:set_string("infotext", title)
		meta:set_string("digtron_id", digtron_id)
		meta:mark_as_private("digtron_id")
	end,
	
	on_rightclick = function(pos, node, clicker, itemstack, pointed_thing)
		local returnstack, success = digtron.on_rightclick(pos, node, clicker, itemstack, pointed_thing)
		if returnstack then
			return returnstack, success
		end

		if clicker == nil then return end
		
		local meta = minetest.get_meta(pos)
		local digtron_id = meta:get_string("digtron_id")
		
		local player_name = clicker:get_player_name()
		
		if digtron_id == "" then		
			if not digtron.recover_digtron_id(pos) then
				minetest.log("error", "[Digtron] The digtron:controller node at " .. minetest.pos_to_string(pos)
					.. " had no digtron id associated with it when " .. player_name
					.. "right-clicked on it. Converting it into a digtron:controller_unassembled.")
				node.name = "digtron:controller_unassembled"
				minetest.set_node(pos, node)
				return
			end
		end
		
		player_interacting_with_digtron_id[player_name] = {digtron_id = digtron_id}
		minetest.show_formspec(player_name,
			"digtron:controller_assembled",
			get_controller_assembled_formspec(digtron_id, player_name))
	end,
}))

minetest.register_lbm({
	label = "Validate and repair Digtron controller metadata",
	name = "digtron:validate_controller_metadata",
	nodenames = {"digtron:controller"},
	run_at_every_load = true,
	action = function(pos, node)
		local meta = minetest.get_meta(pos)
		local digtron_id = meta:get_string("digtron_id")
		if digtron_id == "" then		
			if not digtron.recover_digtron_id(pos) then
				minetest.log("error", "[Digtron] The digtron:controller node at " .. minetest.pos_to_string(pos)
					.. " had no digtron id associated with it. Converting it into a digtron:controller_unassembled.")
				node.name = "digtron:controller_unassembled"
				minetest.set_node(pos, node)
			end
		end		
	end,
})