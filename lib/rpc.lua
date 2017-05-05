-- a sample rpc protocal

local chuck = require("chuck")
local socket = chuck.socket
local buffer = chuck.buffer
local packet = chuck.packet
local log = chuck.log

local cmd_request = 1
local cmd_response = 2

local M = {}
M.seq = 1
M.clients = {}

local logger = log.CreateLogfile("RPC")

local method = {}

function M.registerMethod(methodName,func)
	method[methodName] = func
end

local rpcResponse = {}
rpcResponse.__index = rpcResponse

local function newResponse(conn,seqno)
	local r = {}
	r.conn = conn
	r.seqno = seqno
	r = setmetatable(r, rpcResponse)
	return r
end

local function sendResponse(response,result,err)
	if response.seqno > 0 then
		local resp = {err = err,ret=result}
		local buff = buffer.New()
		local writer = packet.Writer(buff)
		writer:WriteI8(cmd_response)
		writer:WriteI64(response.seqno)
		writer:WriteTable(resp)
		buff = M.pack(buff:Content())
		local err = response.conn:Send(buff)
		if err then
			logger:Log(log.error,string.format("error on sendResponse:%s",err))
		end
	end
end

function rpcResponse:Return(...)
	local result = {...}
	if #result == 0 then
		result = nil
	end
	sendResponse(self,result)
end

local function callMethod(methodName,args,response)
	local func = method[methodName]
	if nil == func then
		logger:Log(log.error,string.format("callMethod method not found:%s",methodName))
		sendResponse(response,nil,"method not found:" .. methodName)
	else
		local errmsg
		local success,ret = xpcall(func,function (err)
		    	errmsg = err
			end,response,table.unpack(args))
		if nil ~= errmsg then
			logger:Log(log.error,string.format("error on callMethod:%s",errmsg))
			sendResponse(response,nil,errmsg)
		end
	end
end


function M.OnRPCMsg(conn,msg)
	local buff = buffer.New(msg)
	local rpacket = packet.Reader(buff)
	local cmd   = rpacket:ReadI8()
	if cmd == cmd_request then
		local seqno = rpacket:ReadI64()
		local name  = rpacket:ReadStr()
		local args  = rpacket:ReadTable()
		local response = newResponse(conn,seqno)
		callMethod(name,args,response)
	elseif cmd == cmd_response then
		local rpcclient = M.clients[conn]
		if not rpcclient then
			return
		end
		local seqno = rpacket:ReadI64()
		local cb = rpcclient.callbacks[seqno]
		if cb then
			rpcclient.callbacks[seqno]= nil
			local resp = rpacket:ReadTable()
			xpcall(cb,function (err)
			    logger:Log(log.error,string.format("error on rpc callback:%s",err))
			end,resp.err,resp.ret)
		end
	else
		logger:Log(log.error,string.format("onRequest unkonw cmd:%d",cmd))
	end
end

local rpcClient = {}
rpcClient.__index = rpcClient

--在一个conn上只能建立一个rpcclient,如果重复建立会失败返回nil
M.RPCClient = function (conn)	
	if M.clients[conn] then
		return nil
	end
	local c = {}
	c.conn = conn
	c.callbacks = {}
	c = setmetatable(c, rpcClient)
	M.clients[conn] = c	
	return c
end

M.pack = function (buff)
	return buffer.New(buff)
end

function rpcClient:Call(methodName,callback,...)

	if nil == methodName then
		return "methodName == nil"
	end

	if nil == self.conn then
		return "connection loss"
	end

	local args = {...}
	local seqno = M.seq

	local buff = buffer.New()
	local writer = packet.Writer(buff)
	writer:WriteI8(cmd_request)
	if nil == callback then
		--不关心返回值，seqno设为0
		writer:WriteI64(0)
	else
		writer:WriteI64(seqno)
		M.seq = M.seq + 1
	end
	writer:WriteStr(methodName)
	writer:WriteTable(args)

	buff = M.pack(buff:Content())
	
	if nil ~= self.conn:Send(buff) then
		return "send request failed"
	else
		if callback then
			self.callbacks[seqno] = callback
		end
	end	
end

function M.OnConnClose(conn)
	local client = M.clients[conn]
	if client then
		for k,cb in pairs(client.callbacks) do
			xpcall(cb,function (err)
				logger:Log(log.error,string.format("error on rpc callback:%s",err))
			end,"connection loss",nil)
		end		
	end
end

return M