require 'sinatra'
require 'sequel'
require 'json'

DB = Sequel.sqlite('test.db')
users = DB[:users]
templates = DB[:templates]
products = DB[:products]
operations = DB[:operations]

post '/operation' do
  request.body.rewind
  data = JSON.parse(request.body.read)

  user_id = data['user_id']
  positions = data['positions']

  current_user = users.where(id: user_id).first
  loyalty_level = templates.where(id: current_user[:template_id]).first

  discount_percentage = loyalty_level[:discount]
  cashback_percentage = loyalty_level[:cashback]

  total_cashback = 0.0
  total_discount = 0.0
  loyal_price = 0.0
  noloyal_price = 0.0

  final_positions = []
  description = "На товар действуют стандартные правила"

  positions.each do |pos|
    total_cost = pos["price"] * pos["quantity"]
    current_product = products.where(id: pos["id"]).first

    unless current_product.nil?
      product_bonus_type, product_bonus_value = current_product[:type], current_product[:value].to_i
    
      if product_bonus_type == "discount"
        discount_percentage = discount_percentage + product_bonus_value
        description = "Скидка #{product_bonus_value}%"
      elsif product_bonus_type == "increased_cashback"
        cashback_percentage = cashback_percentage + product_bonus_value
        description = "Дополнительный кэшбек #{product_bonus_value}%"
      end
    end

    discount = total_cost * discount_percentage / 100.0
    cashback = total_cost * cashback_percentage / 100.0

    if product_bonus_type == "noloyalty"
      discount = 0.0
      cashback = 0.0
      discount_percentage = 0.0
      cashback_percentage = 0.0
      noloyal_price = noloyal_price + total_cost
      description = "Не участвует в программе лояльности"
    else
      total_cashback = total_cashback + cashback
      total_discount = total_discount + discount
      loyal_price = loyal_price + total_cost - discount
    end
    
    hash = {
      id: pos["id"],
      price: pos["price"],
      quantity: pos["quantity"],
      type: product_bonus_type,
      value: product_bonus_value,
      description: description,
      discount_percentage: discount_percentage.round(2),
      discount: discount
    }
    final_positions.push hash

    discount_percentage = loyalty_level[:discount]
    cashback_percentage = loyalty_level[:cashback]
    description = "На товар действуют стандартные правила"
  end

  total_price = loyal_price + noloyal_price
  bonuses = current_user[:bonus].to_i
  allowed_write_off = bonuses > loyal_price ? loyal_price : bonuses

  total_cashback_percentage = (total_cashback / total_price * 100).round(2)
  total_discount_percentage = (total_discount / total_price * 100).round(2)

  operation_id = operations.insert(
    user_id: user_id,
    cashback: total_cashback,
    cashback_percent: total_cashback_percentage,
    discount: total_discount,
    discount_percent: total_discount_percentage,
    write_off: nil,
    check_summ: total_price,
    done: false,
    allowed_write_off: allowed_write_off)

  result = {
    status: 200,
    user: current_user,
    operation_id: operation_id,
    sum: total_price,
    bonus_info: {
      bonuses_balance: current_user[:bonus],
      to_write_off: allowed_write_off,
      total_cashback_percentage: total_cashback_percentage,
      will_be_charged: total_cashback
    },
    discount_info: {
      total_discount: total_discount,
      total_discount_percentage: total_discount_percentage
    },
    positions: final_positions
  }.to_json
end

post '/submit' do
  request.body.rewind
  data = JSON.parse(request.body.read)

  user = data['user']
  operation_id = data['operation_id']
  write_off = data['write_off']

  operation = operations.where(id: operation_id)
  current_operation = operation.first
  #puts write_off

  if current_operation.nil?
    status 405
    return {
      status: 405,
      system_message: "There's no such operation"
    }.to_json
  elsif current_operation[:done]
    status 405
    return {
      status: 405,
      system_message: "This operation has already been finished"
    }.to_json
  elsif user['id'] != current_operation[:user_id]
    status 405
    return {
      status: 405,
      system_message: "This user doesn't have an access to this operation"
    }.to_json
  elsif user['bonus'].to_f < write_off
    status 405
    return {
      status: 405,
      system_message: "Requirement to write off is greater then the current bonus balance"
    }.to_json
  elsif write_off > current_operation[:allowed_write_off]
    status 405
    return {
      status: 405,
      system_message: "Requirement to write off is greater then the allowed amount"
    }.to_json
  end

  correlation = 1 - write_off / current_operation[:allowed_write_off]

  new_sum = (current_operation[:check_summ] - write_off).to_f.round(2)
  new_cashback = (current_operation[:cashback] * correlation).to_f.round(2)
  new_discount = (current_operation[:discount] * correlation).to_f.round(2)
  new_cashback_percentage = (new_cashback / new_sum).to_f.round(2)
  new_discount_percentage = (new_cashback / new_sum).to_f.round(2)

  new_user_bonuses = (users.where(id: user['id']).first[:bonus] - write_off + new_cashback).to_f.round(2)

  operation.update(
    check_summ: new_sum,
    write_off: write_off,
    done: true,
    cashback: new_cashback,
    discount: new_discount,
    cashback_percent: new_cashback_percentage,
    discount_percent: new_discount_percentage
  )
  users.where(id: user['id']).update(bonus: new_user_bonuses)

  result = {
    status: 200,
    system_message: "Ok",
    info: {
      user_id: user['id'],
      bonuses_earned: new_cashback,
      total_cashback_percentage: new_cashback_percentage,
      total_discount: new_discount,
      total_discount_percentage: new_discount_percentage,
      written_off: write_off,
      sum_to_pay: new_sum
    }
  }.to_json
end