#
# Copyright (C) 2011 Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

require File.expand_path(File.dirname(__FILE__) + '/../../spec_helper')

describe Canvas::Security do
  describe "JWT tokens" do
    describe "encoding" do
      describe ".create_jwt" do
        it "should generate a token with an expiration" do
          Timecop.freeze(Time.utc(2013,3,13,9,12)) do
            expires = 1.hour.from_now
            token = Canvas::Security.create_jwt({ a: 1 }, expires)

            expected_token = "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9."\
                             "eyJhIjoxLCJleHAiOjEzNjMxNjk1MjB9."\
                             "VwDKl46gfjFLPAIDwlkVPze1UwC6H_ApdyWYoUXFT8M"
            expect(token).to eq(expected_token)
          end
        end

        it "should generate a token without expiration" do
          token = Canvas::Security.create_jwt({ a: 1 })
          expected_token = "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9."\
                           "eyJhIjoxfQ."\
                           "Pr4RQfnytL0LMwQ0pJXiKoHmEGAYw2OW3pYJTQM4d9I"
          expect(token).to eq(expected_token)
        end

        it "should encode with configured encryption key" do
          jwt = stub
          jwt.expects(:sign).with(Canvas::Security.encryption_key, :HS256).returns("sometoken")
          JSON::JWT.stubs(new: jwt)
          Canvas::Security.create_jwt({ a: 1 })
        end

        it "should encode with the supplied key" do
          jwt = stub
          jwt.expects(:sign).with("mykey", :HS256).returns("sometoken")
          JSON::JWT.stubs(new: jwt)
          Canvas::Security.create_jwt({ a: 1 }, nil, "mykey")
        end
      end

      describe ".create_encrypted_jwt" do
        let(:signing_secret){ "asdfasdfasdfasdfasdfasdfasdfasdf" }
        let(:encryption_secret){ "jkl;jkl;jkl;jkl;jkl;jkl;jkl;jkl;" }

        it "builds up an encrypted token" do
          payload = {arbitrary: "data"}
          jwt = Canvas::Security.create_encrypted_jwt(payload, signing_secret, encryption_secret)
          expect(jwt.length).to eq(225)
        end
      end
    end

    describe ".base64_encode" do
      it "trims off newlines" do
        input = "SuperSuperSuperSuperSuperSuperSuperSuper"\
                 "SuperSuperSuperSuperSuperSuperSuperSuperLongString"
        output = "U3VwZXJTdXBlclN1cGVyU3VwZXJTdXBlclN1cGVy"\
                 "U3VwZXJTdXBlclN1cGVyU3VwZXJTdXBlclN1cGVy"\
                 "U3VwZXJTdXBlclN1cGVyU3VwZXJMb25nU3RyaW5n"
        expect(Canvas::Security.base64_encode(input)).to eq(output)
      end
    end

    describe "decoding" do
      around(:example) do |example|
        Timecop.freeze(Time.utc(2013,3,13,9,12)) do
          @key = "mykey"
          @token_no_expiration = JSON::JWT.new({ a: 1 }).sign(@key, :HS256).to_s
          @token_expired = JSON::JWT.new({ a: 1, 'exp' => 1.hour.ago.to_i }).sign(@key, :HS256).to_s
          @token_not_expired = JSON::JWT.new({ a: 1, 'exp' => 1.hour.from_now.to_i }).sign(@key, :HS256).to_s
          example.run
        end
      end

      it "should decode token" do
        body = Canvas::Security.decode_jwt(@token_no_expiration, [ @key ])
        expect(body).to eq({ "a" => 1 })
      end

      it "should return token body with indifferent access" do
        body = Canvas::Security.decode_jwt(@token_no_expiration, [ @key ])
        expect(body[:a]).to eq(1)
        expect(body["a"]).to eq(1)
      end

      it "should check using past keys" do
        body = Canvas::Security.decode_jwt(@token_no_expiration, [ "newkey", @key ])
        expect(body).to eq({ "a" => 1 })
      end

      it "should raise on an expired token" do
        expect { Canvas::Security.decode_jwt(@token_expired, [ @key ]) }.to raise_error(Canvas::Security::TokenExpired)
      end

      it "should not raise an error on a token with expiration in the future" do
        body = Canvas::Security.decode_jwt(@token_not_expired, [ @key ])
        expect(body[:a]).to eq(1)
      end
    end
  end

  if Canvas.redis_enabled?
    describe "max login attempts" do
      before do
        Setting.set('login_attempts_total', '2')
        Setting.set('login_attempts_per_ip', '1')
        u = user_with_pseudonym :active_user => true,
          :username => "nobody@example.com",
          :password => "asdfasdf"
        u.save!
        @p = u.pseudonym
      end

      it "should be limited for the same ip" do
        expect(Canvas::Security.allow_login_attempt?(@p, "5.5.5.5")).to eq true
        Canvas::Security.failed_login!(@p, "5.5.5.5")
        expect(Canvas::Security.allow_login_attempt?(@p, "5.5.5.5")).to eq false
      end

      it "should have a higher limit for other ips" do
        Canvas::Security.failed_login!(@p, "5.5.5.5")
        expect(Canvas::Security.allow_login_attempt?(@p, "5.5.5.6")).to eq true
        Canvas::Security.failed_login!(@p, "5.5.5.7")
        expect(Canvas::Security.allow_login_attempt?(@p, "5.5.5.8")).to eq false # different ip but too many total failures
        expect(Canvas::Security.allow_login_attempt?(@p, nil)).to eq false # no ip but too many total failures
      end

      it "should not block other users with the same ip" do
        Canvas::Security.failed_login!(@p, "5.5.5.5")
        # schools like to NAT hundreds of people to the same IP, so we don't
        # ever block the IP address as a whole
        u2 = user_with_pseudonym(:active_user => true, :username => "second@example.com", :password => "12341234")
        u2.save!
        expect(Canvas::Security.allow_login_attempt?(u2.pseudonym, "5.5.5.5")).to eq true
        expect(Canvas::Security.allow_login_attempt?(u2.pseudonym, "5.5.5.6")).to eq true
      end

      it "should timeout the login block after a waiting period" do
        Setting.set('login_attempts_ttl', 5.seconds)
        Canvas::Security.failed_login!(@p, "5.5.5.5")
        expect(Canvas::Security.time_until_login_allowed(@p, '5.5.5.6')).to eq 0
        expect(Canvas::Security.time_until_login_allowed(@p, '5.5.5.5')).to be <= 5
      end
    end
  end
end
