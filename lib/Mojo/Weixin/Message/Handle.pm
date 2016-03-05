package Mojo::Weixin;
use strict;
use Mojo::Weixin::Const qw(%KEY_MAP_USER %KEY_MAP_GROUP %KEY_MAP_GROUP_MEMBER %KEY_MAP_FRIEND);
use List::Util qw(first);
use Mojo::Util qw(encode);
use Mojo::Weixin::Message;
use Mojo::Weixin::Message::SendStatus;
use Mojo::Weixin::Const;
use Mojo::Weixin::Message::SendStatus;
use Mojo::Weixin::Message::Queue;
use Mojo::Weixin::Message::Remote::_upload_media;
use Mojo::Weixin::Message::Remote::_send_media_message;
use Mojo::Weixin::Message::Remote::_send_text_message;
$Mojo::Weixin::Message::LAST_DISPATCH_TIME  = undef;
$Mojo::Weixin::Message::SEND_INTERVAL  = 3;

my @logout_code = qw(1100 1101 1102 1205);
sub gen_message_queue{
    my $self = shift;
    Mojo::Weixin::Message::Queue->new(callback_for_get=>sub{
        my $msg = shift;
        return if $self->is_stop;
        if($msg->class eq "recv"){
            $self->emit(receive_message=>$msg);
        }
        elsif($msg->class eq "send"){
            if($msg->source ne "local"){
                my $status = Mojo::Weixin::Message::SendStatus->new(code=>0,msg=>"发送成功",info=>"来自其他设备");
                if(ref $msg->cb eq 'CODE'){
                    $msg->cb->(
                        $self,
                        $msg,
                        $status,
                    );
                }
                $self->emit(send_message=>
                    $msg,
                    $status,
                );
                return;
            }
            #消息的ttl值减少到0则丢弃消息
            if($msg->ttl <= 0){
                $self->debug("消息[ " . $msg->id.  " ]已被消息队列丢弃，当前TTL: ". $msg->ttl);
                my $status = Mojo::Weixin::Message::SendStatus->new(code=>-5,msg=>"发送失败",info=>"TTL失效");
                if(ref $msg->cb eq 'CODE'){
                    $msg->cb->(
                        $self,
                        $msg,
                        $status,
                    );
                }
                $self->emit(send_message=>
                    $msg,
                    $status,
                );
                return;
            }
            my $ttl = $msg->ttl;
            $msg->ttl(--$ttl);

            my $delay = 0;
            my $now = time;
            if(defined $Mojo::Weixin::Message::LAST_DISPATCH_TIME){
                $delay = $now<$Mojo::Weixin::Message::LAST_DISPATCH_TIME+$Mojo::Weixin::Message::SEND_INTERVAL?
                            $Mojo::Weixin::Message::LAST_DISPATCH_TIME+$Mojo::Weixin::Message::SEND_INTERVAL-$now
                        :   0;
            }
            $self->timer($delay,sub{
                $msg->time(time);
                if($msg->format eq "text"){
                    $self->_send_text_message($msg);
                }
                elsif($msg->format eq "media"){
                    $self->_send_media_message($msg);
                }
            });
            $Mojo::Weixin::Message::LAST_DISPATCH_TIME = $now+$delay;
        }
    });
}
sub _parse_synccheck_data{
    my $self = shift;
    my($retcode,$selector) = @_;
    if(defined $retcode and defined $selector){
        if($retcode == 0 and $selector != 0){
            $self->_synccheck_error_count(0);
            $self->_sync();
        }
        elsif($retcode == 0 and $selector == 0){
            $self->_synccheck_error_count(0);
        }
        elsif(first {$retcode == $_} @logout_code){
            $self->relogin($retcode);
            return;
        }
        elsif($self->_synccheck_error_count <= 3){
            my $c = $self->_synccheck_error_count; 
            $self->_synccheck_error_count(++$c);
        }
        else{
            $self->relogin();
            return;
        }
    }
}
sub _parse_sync_data {
    my $self = shift;
    my $json = shift;
    return if not defined $json;
    if(first {$json->{BaseResponse}{Ret} == $_} @logout_code  ){
        $self->relogin($json->{BaseResponse}{Ret});
        return;
    }

    elsif($json->{BaseResponse}{Ret} !=0){
        $self->warn("收到无法识别消息，已将其忽略");
        return;
    }
    $self->sync_key($json->{SyncKey}) if $json->{SyncKey}{Count}!=0;
    $self->skey($json->{SKey}) if $json->{SKey};


    #群组或联系人变更
    if($json->{ModContactCount}!=0){
        for my $e (@{$json->{ModContactList}}){
            if($self->is_group($e->{UserName})){#群组
                my $group = {member=>[]};
                for(keys %KEY_MAP_GROUP){
                    $group->{$_} = defined $e->{$KEY_MAP_GROUP{$_}}?encode("utf8",$e->{$KEY_MAP_GROUP{$_}}):"";
                }
                if($e->{MemberCount} != 0){
                    for my $m (@{$e->{MemberList}}){
                        my $member = {};
                        for(keys %KEY_MAP_GROUP_MEMBER){
                            $member->{$_} = defined $m->{$KEY_MAP_GROUP_MEMBER{$_}}?encode("utf8", $m->{$KEY_MAP_GROUP_MEMBER{$_}}):"";
                        }
                        push @{ $group->{member} }, $member;
                    }
                }
                my $g = $self->search_group(id=>$group->{id});
                if(not defined $g){#新增群组
                    $self->add_group(Mojo::Weixin::Group->new($group));
                }
                else{#更新已有联系人
                    $g->update($group);
                }
            }
            else{#联系人
                my $friend = {};
                for(keys %KEY_MAP_FRIEND){
                    $friend->{$_} = encode("utf8",$e->{$KEY_MAP_FRIEND{$_}}) if defined $e->{$KEY_MAP_FRIEND{$_}};
                }
                my $f = $self->search_friend(id=>$friend->{id});
                if(not defined $f){$self->add_friend(Mojo::Weixin::Friend->new($friend))}
                else{$f->update($friend)}
            }
        }
    }

    if($json->{ModChatRoomMemberCount}!=0){
        
    }

    if($json->{DelContactCount}!=0){
        for my $e (@{$json->{DelContactList}}){
            if($self->is_group($e->{UserName})){
                my $g = $self->search_group(id=>$e->{UserName});
                $self->remove_group($g) if defined $g;
            }
            else{
                my $f = $self->search_friend(id=>$e->{UserName});
                $self->remove_friend($f) if defined $f;
            }
        }
    }

    #有新消息
    if($json->{AddMsgCount} != 0){
        for my $e (@{$json->{AddMsgList}}){
            if($e->{MsgType} == 1){
                my $msg = {};
                $msg->{format} = "text";
                for(keys %KEY_MAP_MESSAGE){$msg->{$_} = defined $e->{$KEY_MAP_MESSAGE{$_}}?encode("utf8",$e->{$KEY_MAP_MESSAGE{$_}}):"";}
                eval{
                    require HTML::Entities;
                    $msg->{content} = HTML::Entities::decode_entities($msg->{content});
                };
                if($@){
                    eval{
                        $msg->{content} = Mojo::Util::html_unescape($msg->{content});
                    };
                    if($@){$self->warn("html entities unescape fail: $@")}
                }
                if($e->{FromUserName} eq $self->user->id){#发送的消息
                    $msg->{source} = 'outer';
                    $msg->{class} = "send";
                    $msg->{sender_id} = $self->user->id;
                    if($self->is_group($e->{ToUserName})){
                        $msg->{type} = "group_message";
                        $msg->{group_id} = $e->{ToUserName};
                    }
                    else{
                        $msg->{type} = "friend_message";
                        $msg->{receiver_id} = $e->{ToUserName};
                    }
                }
                elsif($e->{ToUserName} eq $self->user->id){#接收的消息
                    $msg->{class} = "recv";
                    $msg->{receiver_id} = $self->user->id;
                    if($self->is_group($e->{FromUserName})){#接收到群组消息
                        $msg->{type} = "group_message";
                        $msg->{group_id} = $e->{FromUserName};
                        my ($member_id,$content) = $msg->{content}=~/^(\@.+):<br\/>(.*)/g;
                        if(defined $member_id and defined $content){
                                $msg->{sender_id} = $member_id;
                                $msg->{content} = $content;
                        }
                    }
                    else{
                        $msg->{type} = "friend_message";
                        $msg->{sender_id} = $e->{FromUserName};
                    }
                }

                $self->message_queue->put(Mojo::Weixin::Message->new($msg)); 
            }#MsgType == 1 END
        }
    }

    if($json->{ContinueFlag}!=0){
        $self->_sync();
        return;
    }
}

sub _parse_send_status_data {
    my $self = shift;
    my $json = shift;
    if(defined $json){
        if($json->{BaseResponse}{Ret}!=0){
            return Mojo::Weixin::Message::SendStatus->new(
                        code=>$json->{BaseResponse}{Ret},
                        msg=>"发送失败",
                        info=>encode("utf8",$json->{BaseResponse}{ErrMsg}||"")
                    ); 
        }
        else{
            return Mojo::Weixin::Message::SendStatus->new(code=>0,msg=>"发送成功",info=>"");
        }
    }
    else{
        return Mojo::Weixin::Message::SendStatus->new(code=>-1,msg=>"发送失败",info=>"数据格式错误");
    }
}
sub send_message{
    my $self = shift;
    my $object = shift;
    my $content = shift;
    my $callback = shift;
    if( ref($object) ne "Mojo::Weixin::Friend" and ref($object) ne "Mojo::Weixin::Group") { 
        $self->error("无效的发送消息对象");
        return;
    }
    my $msg = Mojo::Weixin::Message->new(
        id => $self->now(),
        content => $content,
        sender_id => $self->user->id,
        receiver_id => (ref $object eq "Mojo::Weixin::Friend"?$object->id : undef),
        group_id =>(ref $object eq "Mojo::Weixin::Group"?$object->id : undef),
        type => (ref $object eq "Mojo::Weixin::Group"?"group_message":"friend_message"),
        class => "send",
        format => "text", 
    );

    $callback->($self,$msg) if ref $callback eq "CODE"; 
    $self->message_queue->put($msg);

}
sub send_media {
    my $self = shift;
    my $object = shift;
    my $media = shift;
    my $callback = shift;
    if( ref($object) ne "Mojo::Weixin::Friend" and ref($object) ne "Mojo::Weixin::Group") {
        $self->error("无效的发送消息对象");
        return;
    }
    my $media_info = {};
    if(ref $media eq ""){
        $media_info->{media_path} = $media;
    }
    elsif(ref $media eq "HASH"){
        $media_info = $media;
    }
    my $msg = Mojo::Weixin::Message->new(
        id => $self->now(),
        media_id   => $media_info->{media_id},
        media_name => $media_info->{media_name},
        media_path => $media_info->{media_path},
        media_data => $media_info->{media_data},
        media_mime => $media_info->{media_mime},
        media_size => $media_info->{media_size},
        media_mtime => $media_info->{media_mtime},
        media_ext => $media_info->{media_ext},
        content => "[media]($media_info->{media_path})",
        sender_id => $self->user->id,
        receiver_id => (ref $object eq "Mojo::Weixin::Friend"?$object->id : undef),
        group_id =>(ref $object eq "Mojo::Weixin::Group"?$object->id : undef),
        type => (ref $object eq "Mojo::Weixin::Group"?"group_message":"friend_message"),
        class => "send",
        format => "media",
    );

    $callback->($self,$msg) if ref $callback eq "CODE";
    $self->message_queue->put($msg);
}
sub reply_message{
    my $self = shift;
    my $msg = shift;
    my $content = shift;
    my $callback = shift;
    if($msg->class eq "recv"){
        if($msg->type eq "group_message"){
            $self->send_message($msg->group,$content,$callback);
        }
        elsif($msg->type eq "friend_message"){
            $self->send_message($msg->sender,$content,$callback);
        }
    }
    elsif($msg->class eq "send"){
        if($msg->type eq "group_message"){
            $self->send_message($msg->group,$content);
        }
        elsif($msg->type eq "friend_message"){
            $self->send_message($msg->receiver,$content);
        }

    }
}

1;
