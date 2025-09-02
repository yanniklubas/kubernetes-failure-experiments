---@class html
---@field getMatches fun(regex: string): string
---@field extractMatches fun(prefixRegex: string, postfixRegex: string): string
---@field extractMatches fun(prefixRegex: string, matchingRegex: string, postfixRegex: string): string

---@diagnostic disable: undefined-global
---@type html
---@diagnostic disable:lowercase-global
html = html

--[[
	Gets called at the beginning of each "call cycle", perform as much work as possible here.
	Initialize all global variables here.
	Note that math.random is already initialized using a fixed seed (5) for reproducibility.
--]]
---@diagnostic disable:lowercase-global
function onCycle()
	BASE_URL = "http://REPLACE_HOSTNAME:REPLACE_PORT/"
end

--[[
	Gets called with ever increasing callnums for each http call until it returns nil.
	Once it returns nil, onCycle() is called again and callnum is reset to 1 (Lua convention).

	Here, you can use our HTML helper functions for conditional calls on returned texts (usually HTML, thus the name).
	We offer:
	- html.getMatches( regex )
		Returns all lines in the returned text stream that match a provided regex.
	- html.extractMatches( prefixRegex, postfixRegex )
		Returns all matches that are preceded by a prefixRegex match and followed by a postfixRegex match.
		The regexes must have one unique match for each line in which they apply.
	- html.extractMatches( prefixRegex, matchingRegex, postfixRegex )
		Variant of extractMatches with a matching regex defining the string that is to be extracted.
--]]
---@diagnostic disable:lowercase-global
function onCall(callnum)
	if callnum == 4 then
		local userlist = html.extractMatches("anonymous-", "\\d+", '"}')
		USER_ID = userlist[math.random(#userlist)]
	elseif callnum == 6 then
		local productlist = html.extractMatches('sku":"', "[a-zA-Z]+", '"')
		local instocklist = html.extractMatches('instock":', "\\d+", ",")
		while true do
			local index = math.random(#productlist)
			if instocklist[index] ~= "0" then
				PRODUCT_ID = productlist[index]
				break
			end
		end
	elseif callnum == 13 then
		local codelist = html.extractMatches('code":"', "[a-zA-Z]+", '"')
		local namelist = html.extractMatches('name":"', "[a-zA-Z]+", '"')
		local codeindex = math.random(#codelist)
		CODE = codelist[codeindex]
		COUNTRY_NAME = namelist[codeindex]
	elseif callnum == 14 then
		local uuidlist = html.extractMatches('uuid":', "\\d+", ",")
		local citynamelist = html.extractMatches('name":"', "[a-zA-Z]+", '"')
		local cityindex = math.random(#uuidlist)
		CITY_ID = uuidlist[cityindex]
		CITY_NAME = citynamelist[cityindex]
	elseif callnum == 15 then
		local responseWithoutClosingBracket = html.extractMatches("\\{", "(\\})(?!.*\\})")
		SHIPPING_OBJECT = responseWithoutClosingBracket[math.random(#responseWithoutClosingBracket)]
	elseif callnum == 16 then
		local cartWithoutClosingBracket = html.extractMatches("\\{", "(\\})(?!.*\\})")
		FINAL_CART_OBJECT = cartWithoutClosingBracket[math.random(#cartWithoutClosingBracket)]
	end

	if callnum == 1 then
		return "[POST]" .. BASE_URL .. 'api/user/login[JSON]{"name":"user","password":"password"}'
	elseif callnum == 2 then
		return BASE_URL
	elseif callnum == 3 then
		return BASE_URL .. "api/user/uniqueid"
	elseif callnum == 4 then
		return BASE_URL .. "api/catalogue/categories"
	elseif callnum == 5 then
		return BASE_URL .. "api/catalogue/products"
	elseif callnum == 6 then
		local rating = 1 + math.random(5)
		return "[PUT]" .. BASE_URL .. "api/ratings/api/rate/" .. PRODUCT_ID .. "/" .. rating
	elseif callnum == 7 then
		return BASE_URL .. "api/catalogue/product/" .. PRODUCT_ID
	elseif callnum == 8 then
		return BASE_URL .. "api/ratings/api/fetch/" .. PRODUCT_ID
	elseif callnum == 9 then
		return BASE_URL .. "api/cart/add/anonymous-" .. USER_ID .. "/" .. PRODUCT_ID .. "/1"
	elseif callnum == 10 then
		return BASE_URL .. "api/cart/cart/anonymous-" .. USER_ID
	elseif callnum == 11 then
		return BASE_URL .. "api/cart/update/anonymous-" .. USER_ID .. "/" .. PRODUCT_ID .. "/1"
	elseif callnum == 12 then
		return BASE_URL .. "api/shipping/codes"
	elseif callnum == 13 then
		return BASE_URL .. "api/shipping/cities/" .. CODE
	elseif callnum == 14 then
		return BASE_URL .. "api/shipping/calc/" .. CITY_ID
	elseif callnum == 15 then
		return "[POST]"
			.. BASE_URL
			.. "api/shipping/confirm/anonymous-"
			.. USER_ID
			.. "[JSON]{"
			.. SHIPPING_OBJECT
			.. ',"location":"'
			.. COUNTRY_NAME
			.. " "
			.. CITY_NAME
			.. '"}'
	elseif callnum == 16 then
		return "[POST]" .. BASE_URL .. "api/payment/pay/anonymous-" .. USER_ID .. "[JSON]{" .. FINAL_CART_OBJECT .. "}"
	end
	return nil
end
