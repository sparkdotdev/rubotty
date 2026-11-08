# frozen_string_literal: true

# A Net::HTTPResponse double that hands its body over in chunks, the way the real one does
# when it is given a block. Needed because the scripting endpoint reads its response as it
# arrives and stops at the cap, rather than buffering the whole body and truncating
# afterwards, so a double answering only to #body no longer stands in for one.
module StreamingResponses
  def streaming_response(body, type, code: "200", chunk_size: 8192)
    response = instance_double(Net::HTTPResponse, code: code)
    allow(response).to receive(:[]).with("content-type").and_return(type)
    allow(response).to receive(:read_body) do |&block|
      body.to_s.each_char.each_slice(chunk_size) { |slice| block.call(slice.join) }
    end
    response
  end
end

RSpec.configure { |config| config.include StreamingResponses }
