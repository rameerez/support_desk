# frozen_string_literal: true

class CreateDummyHostTables < ActiveRecord::Migration[7.2]
  def change
    create_table :users do |t|
      t.string :name, null: false
      t.string :email
      t.boolean :admin, null: false, default: false
      t.boolean :onboarded, null: false, default: true
      t.timestamps
    end

    create_table :orders do |t|
      t.references :user, null: false, foreign_key: true
      t.string :number, null: false
      t.string :state, null: false, default: "paid"
      t.decimal :total, precision: 10, scale: 2, default: "0.0"
      t.timestamps
    end

    create_table :invoices do |t|
      t.references :user, null: false, foreign_key: true
      t.string :number, null: false
      t.timestamps
    end
  end
end
