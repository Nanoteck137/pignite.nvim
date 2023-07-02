local Popup = require("nui.popup")
local Line = require("nui.line")
local Tree = require("nui.tree")
local event = require("nui.utils.autocmd").event

local M = {}

local function shell_error()
	return vim.v.shell_error ~= 0
end

local function is_list(id)
	return id:find("^list_") ~= nil
end

local function is_item(id)
	return id:find("^list_") ~= nil
end

local function create_item_node(item)
	return Tree.Node({
		id = "item_" .. item.id,
		real_id = item.id,
		text = item.name,
		done = item.done,
	})
end

local function create_list_node(list, items)
	return Tree.Node({
		id = "list_" .. list.id,
		real_id = list.id,
		text = list.name,
	}, items)
end

local function get_nodes(p)
	local nodes = {}

	for _, list in ipairs(p.lists) do
		local children = {}

		for _, item in ipairs(list.items) do
			table.insert(children, create_item_node(item))
		end

		table.insert(nodes, create_list_node(list, children))
	end

	return nodes
end

M.get_project = function(project_id)
	-- TODO(patrik): Errors
	local json = vim.fn.system({ "onix", "get-project", project_id })
	if shell_error() then
		return nil
	end

	return vim.json.decode(json)
end

M.open_project = function(project_id)
	local project = M.get_project(project_id)

	if not project then
		return
	end

	local popup = Popup({
		enter = true,
		position = "50%",
		size = {
			width = "50%",
			height = "60%",
		},
		border = {
			style = "rounded",
			text = {
				top = project.name,
			},
		},
		buf_options = {
			readonly = true,
			modifiable = false,
		},
		win_options = {
			winhighlight = "Normal:Normal,FloatBorder:Normal",
		},
	})

	popup:mount()

	popup:on({ event.BufWinLeave }, function()
		vim.schedule(function()
			popup:unmount()
		end)
	end, { once = true })

	local tree = Tree({
		winid = popup.winid,
		nodes = get_nodes(project),
		prepare_node = function(node)
			local line = Line()

			if is_list(node.id) then
				line:append(node:is_expanded() and " " or " ", "SpecialChar")
				line:append(node.text)
				if not node:has_children() then
					line:append(" (empty)")
				end

				return line
			end

			line:append("  ")

			if node.done then
				line:append("[x]", "@text.todo.checked")
			else
				line:append("[ ]", "@text.todo.unchecked")
			end
			line:append(" " .. node.text)

			return line
		end,
	})

	local map_options = { remap = false, nowait = false }

	-- exit
	popup:map("n", { "q", "<esc>" }, function()
		popup:unmount()
	end, map_options)

	popup:on(event.BufLeave, function()
		popup:unmount()
	end)

	-- collapse
	popup:map("n", "h", function()
		local node, linenr = tree:get_node()
		if not node:has_children() then
			node, linenr = tree:get_node(node:get_parent_id())
		end
		if node and node:collapse() then
			vim.api.nvim_win_set_cursor(popup.winid, { linenr, 0 })
			tree:render()
		end
	end, map_options)

	-- expand
	popup:map("n", "l", function()
		local node, linenr = tree:get_node()
		if not node:has_children() then
			node, linenr = tree:get_node(node:get_parent_id())
		end
		if node and node:expand() then
			vim.api.nvim_win_set_cursor(popup.winid, { linenr, 0 })
			tree:render()
		end
	end, map_options)

	-- New List
	popup:map("n", "nl", function()
		vim.ui.input({ prompt = "List Name: " }, function(input)
			if not input then
				return
			end

			local res = vim.fn.system({ "onix", "new-list", project_id, input })
			if not shell_error() then
				local data = vim.json.decode(res)
				local new_node = create_list_node(data, {})

				tree:add_node(new_node)
				tree:render()
			else
				vim.notify("Failed to create new list", vim.log.levels.ERROR)
			end
		end)
	end, map_options)

	-- New List Item
	popup:map("n", "ni", function()
		local node = tree:get_node()
		local node_id = node.id

		vim.ui.input({ prompt = "Item Name: " }, function(input)
			if not input then
				return
			end

			local parent_id = node:get_id()
			if is_item(node_id) then
				parent_id = node:get_parent_id()
			end

			local parent_node = tree:get_node(parent_id)
			local list_id = parent_node.real_id

			local res = vim.fn.system({ "onix", "new-list-item", list_id, input })
			if not shell_error() then
				local data = vim.json.decode(res)
				local new_node = create_item_node(data)

				tree:add_node(new_node, parent_id)
				tree:render()
			else
				vim.notify("Failed to create new list item", vim.log.levels.ERROR)
			end
		end)
	end, map_options)

	-- Delete
	popup:map("n", "dd", function()
		local node = tree:get_node()
		local node_id = node.id

		if is_list(node_id) then
			local list_id = node.real_id

			vim.ui.input({ prompt = "Are you sure (y/n)" }, function(input)
				if input == "y" then
					vim.fn.system({ "onix", "delete-list", list_id })
					if not shell_error() then
						tree:remove_node(node:get_id())
						tree:render()
					else
						vim.notify("Failed to delete list", vim.log.levels.ERROR)
					end
				end
			end)
		end

		if is_item(node_id) then
			local item_id = node.real_id
			vim.ui.input({ prompt = "Are you sure (y/n)" }, function(input)
				if input == "y" then
					vim.fn.system({ "onix", "delete-list-item", item_id })
					if not shell_error() then
						tree:remove_node(node:get_id())
						tree:render()
					else
						vim.notify("Failed to delete list item", vim.log.levels.ERROR)
					end
				end
			end)
		end
	end, map_options)

	-- Mark
	popup:map("n", "m", function()
		local node = tree:get_node()
		local node_id = node.id

		if is_item(node_id) then
			local item_id = node.real_id
			local updated = not node.done

			vim.fn.system({ "onix", "update-item", item_id, tostring(updated) })
			if not shell_error() then
				node.done = not node.done
				tree:render()
			else
				vim.notify("Failed to update list item", vim.log.levels.ERROR)
			end
		end
	end, map_options)

	-- refresh
	popup:map("n", "r", function()
		vim.schedule(function()
			-- TODO(patrik): Smarter way to refresh the nodes
			local s = vim.fn.system({ "onix", "get-project", project_id })
			project = vim.json.decode(s)
			local nodes = get_nodes(project)
			tree:set_nodes(nodes)
			tree:render()
		end)
	end, map_options)

	tree:render()
end

M.pick_project = function()
	local s = vim.fn.system({ "onix", "get-all-projects" })
	local projects = vim.json.decode(s)

	if projects then
		vim.ui.select(projects, {
			prompt = "Choose project:",
			format_item = function(item)
				return item.name
			end,
		}, function(choice)
			if choice then
				M.recent_opened = choice
				M.open_project(choice.id)
			end
		end)
	end
end

M.open_recent_project = function()
	if M.recent_opened then
		M.open_project(M.recent_opened.id)
	else
		vim.notify("No recent project", vim.log.levels.ERROR)
	end
end

return M
